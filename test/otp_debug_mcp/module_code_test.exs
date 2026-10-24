defmodule OtpDebugMcp.ModuleCodeTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}

  # Modules on the target's code path, as a release's are: macro-generated
  # functions with debug info, the same stripped as `mix release` strips
  # them, an Erlang module with an include file, and line numbers that
  # need the line table's longer encodings.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "otpdbg_code_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "routes.ex"), """
    defmodule OtpdbgCode.Routes do
      defmacro route(path, handler) do
        quote do
          def handle(unquote(path), conn), do: unquote(handler).(conn)
        end
      end

      defmacro kept(name) do
        quote location: :keep do
          def unquote(name)(x), do: {unquote(name), x * 2}
        end
      end
    end

    defmodule OtpdbgCode.Shop do
      require OtpdbgCode.Routes
      OtpdbgCode.Routes.route("/price", fn c -> {:price, c} end)
      OtpdbgCode.Routes.route("/stock", fn c -> {:stock, c} end)
      OtpdbgCode.Routes.kept(:double)
      for n <- [:a, :b], do: def(unquote(:"get_\#{n}")(), do: unquote(n))
    end

    defmodule OtpdbgCode.Cache do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
      @impl true
      def init(state), do: {:ok, state}
    end

    # Like Phoenix.Router's __match_route__/3: a function a macro defines
    # without recording it as the macro's, on the line the macro was used.
    defmodule OtpdbgCode.Untagged do
      defmacro __using__(_) do
        quote do
          @before_compile OtpdbgCode.Untagged
          @use_line __ENV__.line
          def tagged, do: :tagged
        end
      end

      defmacro __before_compile__(env) do
        line = Module.get_attribute(env.module, :use_line)
        Code.eval_quoted(Code.string_to_quoted!("def untagged(x), do: x", line: line), [], env)
        :ok
      end
    end

    defmodule OtpdbgCode.UsesUntagged do
      use OtpdbgCode.Untagged
      def mine, do: :mine
    end

    defmodule OtpdbgCode.Stripped do
      use GenServer
      def init(state), do: {:ok, state}
    end
    """)

    # ExUnit compiles without debug info; a project's build has it.
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    {:ok, _modules, _} =
      Kernel.ParallelCompiler.compile_to_path([Path.join(dir, "routes.ex")], dir,
        return_diagnostics: true
      )

    Code.put_compiler_option(:debug_info, debug_info)

    # As mix release does by default: debug info and compile info go.
    {:ok, _} = :beam_lib.strip(~c"#{dir}/Elixir.OtpdbgCode.Stripped.beam")

    File.write!(Path.join(dir, "otpdbg_code_defs.hrl"), """
    -define(TWICE(X), (X) * 2).
    included(X) -> {included, X}.
    """)

    File.write!(Path.join(dir, "otpdbg_code_erl.erl"), """
    -module(otpdbg_code_erl).
    -export([twice/1, included/1]).
    -include("otpdbg_code_defs.hrl").
    twice(X) -> ?TWICE(X).
    """)

    # Functions far down the file: line numbers past 2047 and 65535.
    File.write!(Path.join(dir, "otpdbg_code_long.erl"), """
    -module(otpdbg_code_long).
    -export([at_3000/0, at_70000/0]).
    #{String.duplicate("\n", 2_997)}at_3000() -> ok.
    #{String.duplicate("\n", 66_999)}at_70000() -> ok.
    """)

    for erl <- ["otpdbg_code_erl.erl", "otpdbg_code_long.erl"] do
      {:ok, _} =
        :compile.file(~c"#{Path.join(dir, erl)}", [:debug_info, outdir: ~c"#{dir}", i: ~c"#{dir}"])
    end

    target = TestTarget.start()
    true = TestTarget.call(target, :code, :add_patha, [~c"#{dir}"])

    on_exit(fn ->
      TestTarget.stop(target)
      File.rm_rf!(dir)
    end)

    %{target: target, dir: dir}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp code(params), do: call_tool_json(Tools.ModuleCode, params)

  defp function(result, name), do: Enum.find(result["functions"], &(&1["function"] == name))

  test "tells functions macros generated from those written in the module" do
    assert {:ok, result} = code(%{module: "OtpdbgCode.Shop"})
    assert result["debug_info"] =~ "after macro expansion"
    assert result["source"] =~ "routes.ex"

    assert %{
             "generated_by" => "a macro of OtpdbgCode.Routes",
             "called_at" => called,
             "clauses" => 2
           } =
             function(result, "handle/2")

    assert called =~ ~r/routes\.ex:17$/

    # quote location: :keep also says where in the macro.
    assert %{"called_at" => _, "macro_code_at" => macro_at} = function(result, "double/1")
    assert macro_at =~ ~r/routes\.ex:10$/

    # Functions a for loop defines in the module body are written there.
    assert %{"written_at" => written} = function(result, "get_a/0")
    assert written =~ ~r/routes\.ex:20$/
    refute Map.has_key?(function(result, "get_a/0"), "generated_by")

    assert "module_info/0" in result["compiler_generated"]

    # A macro is listed, and shown, as its source names it.
    assert {:ok, routes} = code(%{module: "OtpdbgCode.Routes"})
    assert %{"kind" => "defmacro", "written_at" => _} = function(routes, "route/2")

    assert {:ok, %{"code" => [%{"function" => "route/2", "code" => text, "note" => note}]}} =
             code(%{module: "OtpdbgCode.Routes", function: "route/2"})

    assert text =~ "defmacro route(path, handler)"
    assert note =~ "the functions it generated"
    assert result["loaded"] =~ "not loaded" or result["loaded"] =~ "this file's"
  end

  test "a function defined untagged on a macro's line is that macro's, probably" do
    assert {:ok, result} = code(%{module: "OtpdbgCode.UsesUntagged"})

    assert %{"generated_by" => "a macro of OtpdbgCode.Untagged", "called_at" => at} =
             function(result, "tagged/0")

    assert %{
             "generated_by" => "probably a macro of OtpdbgCode.Untagged",
             "called_at" => ^at,
             "note" => _
           } =
             function(result, "untagged/1")

    assert %{"written_at" => _} = function(result, "mine/0")
  end

  test "names use GenServer's callbacks as generated by GenServer" do
    assert {:ok, result} = code(%{module: "OtpdbgCode.Cache"})

    for callback <- [
          "handle_call/3",
          "handle_cast/2",
          "handle_info/2",
          "terminate/2",
          "child_spec/1"
        ] do
      assert %{"generated_by" => "a macro of GenServer", "macro_code_at" => at} =
               function(result, callback)

      assert at =~ "gen_server.ex:"
    end

    assert %{"written_at" => _} = function(result, "init/1")
  end

  test "shows a function's code after macro expansion" do
    assert {:ok,
            %{"code" => [%{"function" => "handle/2", "language" => "elixir", "code" => text}]}} =
             code(%{module: "OtpdbgCode.Shop", function: "handle"})

    assert text =~ ~s{def handle("/price", conn)}
    assert text =~ ~s{def handle("/stock", conn)}

    assert {:ok, %{"code" => [%{"code" => text}]}} =
             code(%{module: "OtpdbgCode.Shop", function: "double/1"})

    assert text =~ "def double(x)"
  end

  test "a stripped module: origins from the line table, and assembly" do
    assert {:ok, result} = code(%{module: "OtpdbgCode.Stripped"})
    assert result["debug_info"] =~ "no debug info"
    assert result["source"] =~ "unknown"

    {own, macro} =
      Enum.split_with(Map.keys(result["by_file"]), &String.ends_with?(&1, "routes.ex"))

    assert result["by_file"][hd(own)] == ["init/1"]
    assert [gen_server] = macro
    assert gen_server =~ "gen_server.ex"
    assert "handle_call/3" in result["by_file"][gen_server]

    assert {:ok, %{"code" => [%{"language" => "beam assembly" <> _, "code" => text}]}} =
             code(%{module: "OtpdbgCode.Stripped", function: "handle_call/3"})

    assert text =~ "% " <> gen_server
    assert text =~ "func_info"
  end

  test "finds the function a stack frame is in", %{dir: dir} do
    # A frame points into a function's body; take a line only handle_info has.
    info =
      "#{dir}/Elixir.OtpdbgCode.Stripped.beam" |> File.read!() |> OtpDebugMcp.ModuleCode.analyze()

    lines_of = fn name ->
      info.functions |> Enum.find(&(&1.name == name)) |> Map.fetch!(:lines)
    end

    others =
      Enum.flat_map([:handle_call, :handle_cast, :terminate, :code_change, :child_spec], lines_of)

    {file, line} = Enum.find(lines_of.(:handle_info), &(&1 not in others))
    frame = "#{Path.basename(file)}:#{line}"

    assert {:ok, %{"at" => ^frame, "in" => [%{"function" => "handle_info/2", "defined_at" => _}]}} =
             code(%{module: "OtpdbgCode.Stripped", at: frame})

    assert {:error, text} = code_error(%{module: "OtpdbgCode.Stripped", at: "gen_server.ex:1"})
    assert text =~ "no function"
  end

  test "an Erlang module: code from an include file, and its code as Erlang" do
    assert {:ok, result} = code(%{module: "otpdbg_code_erl"})
    assert result["debug_info"] =~ "erlang"
    assert %{"generated_from" => from} = function(result, "included/1")
    assert from =~ "otpdbg_code_defs.hrl:2"
    assert %{"written_at" => _} = function(result, "twice/1")

    assert {:ok, %{"code" => [%{"language" => "erlang", "code" => text}]}} =
             code(%{module: "otpdbg_code_erl", function: "twice"})

    assert text =~ "twice(X) ->"
  end

  test "decodes line numbers that need the longer encodings" do
    assert {:ok, result} = code(%{module: "otpdbg_code_long"})
    assert function(result, "at_3000/0")["written_at"] =~ ~r/:3000$/
    assert function(result, "at_70000/0")["written_at"] =~ ~r/:70000$/
  end

  test "says when the running version isn't the file's", %{target: target, dir: dir} do
    {:module, _} = TestTarget.call(target, :code, :load_file, [:otpdbg_code_long])
    {:ok, result} = code(%{module: "otpdbg_code_long"})
    assert result["loaded"] =~ "this file's"

    {:ok, :otpdbg_code_long, bin} =
      :compile.forms(
        [
          {:attribute, 1, :module, :otpdbg_code_long},
          {:attribute, 1, :export, [{:x, 0}]},
          {:function, 2, :x, 0, [{:clause, 2, [], [], [{:atom, 2, :x}]}]}
        ],
        [:binary]
      )

    TestTarget.call(target, :code, :purge, [:otpdbg_code_long])

    {:module, _} =
      TestTarget.call(target, :code, :load_binary, [:otpdbg_code_long, ~c"#{dir}/x", bin])

    {:ok, result} = code(%{module: "otpdbg_code_long"})
    assert result["loaded"] =~ "hot-loaded"
  end

  test "explains what it can't read" do
    assert {:error, text} = code_error(%{module: "OtpDebugMcp.Fixtures.Busy"})
    assert text =~ "not from a file on the target's code path"

    assert {:error, text} = code_error(%{module: "no_such_module"})
    assert text =~ "module_not_found_on_target"

    assert {:error, text} = code_error(%{module: "OtpdbgCode.Shop", function: "nope"})
    assert text =~ "no function nope"

    assert {:error, text} = code_error(%{module: "OtpdbgCode.Shop", function: "handle/x"})
    assert text =~ "name/arity"
  end

  defp code_error(params), do: call_tool(Tools.ModuleCode, params)
end
