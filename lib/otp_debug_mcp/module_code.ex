defmodule OtpDebugMcp.ModuleCode do
  @moduledoc """
  What a module on the target really contains, macro-generated functions
  included: every function with where it came from, one function's code as
  it runs, and which function a stack frame's `file:line` is in.

  The module's .beam is read from the target's code path and decoded here,
  so nothing runs on the target but `code:get_object_code/1`. What it can
  tell depends on what the .beam kept:

    * **Elixir debug info** (dev and test builds, and releases built with
      `strip_beams: [keep: ["Dbgi"]]`): the code after macro expansion. A
      function a macro generated records the macro's module and the line
      that called it, and with `quote location: :keep` also the line in
      the macro.
    * **Erlang debug info**: the abstract code, shown as Erlang.
    * **Neither**, as in a default `mix release`, which strips debug info:
      the line table, which stack traces need and so is always kept,
      still says which file each function's code is from, so code a macro
      generated shows up as code from the macro's file. Its code is the
      BEAM assembly.
  """

  alias OtpDebugMcp.{Checks, Target, Tracer}

  @fetch ~S"""
  case code:get_object_code(Mod) of
    {Mod, Bin, File} ->
      Loaded = case code:is_loaded(Mod) of
                 false -> not_loaded;
                 _ -> erlang:get_module_info(Mod, md5)
               end,
      {ok, Bin, File, Loaded};
    error ->
      case code:is_loaded(Mod) of
        {file, preloaded} -> preloaded;
        {file, _} -> not_on_code_path;
        false -> not_found
      end
  end.
  """

  @doc """
  Fetches `module_str`'s object code from the target and decodes it.
  """
  def fetch(module_str) do
    mod = module_str |> String.trim("'") |> Tracer.resolve_module()

    case Checks.remote_eval(@fetch, Mod: mod) do
      {:ok, {:ok, bin, file, loaded}} ->
        {:ok,
         bin |> analyze(&disassemble_here_or_there/1) |> Map.merge(loaded(bin, file, loaded))}

      {:ok, :preloaded} ->
        {:error, "#{module_str} is preloaded into the VM: it has no .beam to read"}

      {:ok, :not_on_code_path} ->
        {:error, not_on_code_path(module_str)}

      {:ok, :not_found} ->
        {:error, {:module_not_found_on_target, module_str}}

      {:error, _} = err ->
        err
    end
  end

  defp not_on_code_path(module_str) do
    "#{module_str} is loaded, but not from a file on the target's code path (it was compiled " <>
      "in memory, from a script or with load_module), so there's no .beam to read"
  end

  defp loaded(bin, file, loaded) do
    {:ok, {_, md5}} = :beam_lib.md5(bin)

    %{
      beam_file: to_string(file),
      loaded:
        case loaded do
          :not_loaded ->
            "not loaded: this is the version the node would load"

          ^md5 ->
            "the version running is this file's"

          _ ->
            "differs: the version running isn't this file's (it was hot-loaded), so this may not be the code that runs"
        end
    }
  end

  # This node's beam_disasm can't read a newer OTP's .beam (it fails on
  # the newer type chunk and instructions), but the target's can, if it
  # has the compiler application, as Elixir releases do.
  defp disassemble_here_or_there(bin) do
    with :error <- disassemble(bin) do
      case Target.rpc(:beam_disasm, :file, [bin], 15_000) do
        {:ok, {:beam_file, _, _, _, _, _} = disasm} -> {:ok, from_disasm(disasm), :target}
        _ -> :error
      end
    end
  end

  @doc """
  Decodes a .beam: its module, source, which debug info it has, and its
  functions with their lines and, where the debug info says, their
  origin. `disassemble` returns `{:ok, {exports, functions}, where}` or
  `:error`.
  """
  def analyze(bin, disassemble \\ &disassemble/1) do
    {:ok, mod} = beam_module(bin)

    {{exports, functions}, disassembled} =
      case disassemble.(bin) do
        {:ok, result, where} -> {result, where}
        :error -> {from_tables(bin), :no}
      end

    {kind, defs} = debug_info(bin, mod)
    source = elixir_source(defs) || compiled_source(bin)

    # File 0 in the line table is the module's own, which it doesn't name.
    own = source || "the module's own file"

    table =
      bin
      |> line_table()
      |> Enum.map(fn {file, line} -> {if(file == "", do: own, else: file), line} end)
      |> List.to_tuple()

    %{
      module: mod,
      source: source,
      debug_info: kind,
      disassembled: disassembled,
      defs: defs,
      functions:
        for {name, arity, instrs} <- functions do
          instrs = Enum.map(instrs, &resolve_line(&1, table, own))

          %{
            name: name,
            arity: arity,
            exported: {name, arity} in exports,
            lines: for({:line, {_, _} = loc} <- instrs, uniq: true, do: loc),
            instrs: instrs
          }
        end
    }
  end

  defp beam_module(bin) do
    case :beam_lib.info(bin) do
      info when is_list(info) -> {:ok, info[:module]}
      {:error, :beam_lib, reason} -> {:error, reason}
    end
  end

  defp elixir_source(%{relative_file: file}) when is_binary(file), do: file
  defp elixir_source(_), do: nil

  # A release strips the compile info too, and with it the source path.
  defp compiled_source(bin) do
    with {:ok, {_, [compile_info: info]}} <- :beam_lib.chunks(bin, [:compile_info]),
         source when is_list(source) <- info[:source] do
      to_string(source)
    else
      _ -> nil
    end
  end

  defp disassemble(bin) do
    case :beam_disasm.file(bin) do
      {:beam_file, _, _, _, _, _} = disasm -> {:ok, from_disasm(disasm), :here}
      _error -> :error
    end
  catch
    _, _ -> :error
  end

  defp from_disasm({:beam_file, _mod, exports, _attrs, _info, code}) do
    {for({name, arity, _label} <- exports, do: {name, arity}),
     for({:function, name, arity, _entry, instrs} <- code, do: {name, arity, instrs})}
  end

  # Without a disassembly: the names from the export and local function
  # tables, without their code or lines.
  defp from_tables(bin) do
    case :beam_lib.chunks(bin, [:exports, :locals]) do
      {:ok, {_, [exports: exports, locals: locals]}} ->
        {exports, for({name, arity} <- exports ++ locals, do: {name, arity, []})}

      _ ->
        {[], []}
    end
  end

  # Elixir's debug info has the module after macro expansion; Erlang's,
  # the abstract code. Either can be missing (stripped) or unreadable
  # (encrypted, or from an Elixir this one can't read).
  defp debug_info(bin, mod) do
    with {:ok, {^mod, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(bin, [:debug_info]) do
      case backend do
        :elixir_erl ->
          case safely(fn -> backend.debug_info(:elixir_v1, mod, data, []) end) do
            {:ok, map} -> {:elixir, map}
            _ -> erlang_debug_info(backend, mod, data)
          end

        _ ->
          erlang_debug_info(backend, mod, data)
      end
    else
      _ -> {:none, nil}
    end
  end

  defp erlang_debug_info(backend, mod, data) do
    case safely(fn -> backend.debug_info(:erlang_v1, mod, data, []) end) do
      {:ok, forms} -> {:erlang, %{forms: forms}}
      _ -> {:none, nil}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  A function's name and arity as its source names it: the compiler
  turns a macro `timed/2` into the function `MACRO-timed/3`, whose first
  argument is the caller's environment.
  """
  def source_name(%{name: name, arity: arity}) do
    case Atom.to_string(name) do
      "MACRO-" <> macro -> {macro, arity - 1}
      other -> {other, arity}
    end
  end

  @doc "How to show a function: name/arity, an anonymous fn after the function it's in."
  def label(f) do
    {name, arity} = source_name(f)

    case Regex.run(~r{^-(.+)/(\d+)-fun-\d+-$}, name) do
      [_, outer, outer_arity] -> "anonymous fn/#{arity} in #{outer}/#{outer_arity}"
      nil -> "#{name}/#{arity}"
    end
  end

  # The debug info names a macro as its source does.
  defp def_key(f) do
    {name, arity} = source_name(f)
    {String.to_atom(name), arity}
  end

  # A function asked for by its source name, or by its compiled one.
  defp named?(f, name, arity) do
    {source, source_arity} = source_name(f)

    (source == name and (arity == nil or source_arity == arity)) or
      (Atom.to_string(f.name) == name and (arity == nil or f.arity == arity))
  end

  @doc """
  The origin of one function, as a map for the tool's output.
  """
  def origin(%{debug_info: :elixir, defs: defs, source: source}, f) do
    case Enum.find(defs.definitions, fn {fa, _, _, _} -> fa == def_key(f) end) do
      {_, kind, meta, clauses} -> elixir_origin(kind, meta, clauses, source, macro_lines(defs))
      nil -> compiler_origin(f) || line_origin(f, source)
    end
  end

  def origin(%{source: source}, f), do: compiler_origin(f) || line_origin(f, source)

  # The lines where macros were called, and whose: where functions a
  # macro generated say it was called.
  defp macro_lines(defs) do
    for {_, _, meta, _} <- defs.definitions,
        meta[:context],
        into: %{},
        do: {meta[:line], meta[:context]}
  end

  defp elixir_origin(kind, meta, clauses, source, macro_lines) do
    base = %{kind: to_string(kind), clauses: length(clauses)}

    case {meta[:context], Map.get(macro_lines, meta[:line])} do
      # Some macros define functions in a way that doesn't record them as
      # the macro's (Phoenix.Router's __match_route__/3, built in its
      # __before_compile__). One defined on the line where a macro was
      # called, as `use` is, is that macro's, not code written there.
      {nil, context} when context != nil ->
        base
        |> Map.put(:generated_by, "probably a macro of #{inspect(context)}")
        |> Map.put(:called_at, "#{source}:#{meta[:line]}")
        |> Map.put(
          :note,
          "the debug info doesn't name the macro, but it's defined on the line where " <>
            "#{inspect(context)}'s macro was called"
        )

      {nil, nil} ->
        Map.put(base, :written_at, "#{source}:#{meta[:line]}")

      {context, _} ->
        base
        |> Map.put(:generated_by, "a macro of #{inspect(context)}")
        |> Map.put(:called_at, "#{source}:#{meta[:line]}")
        |> then(fn m ->
          case meta[:file] do
            {file, line} -> Map.put(m, :macro_code_at, "#{file}:#{line}")
            _ -> m
          end
        end)
    end
  end

  # Functions the compiler adds, which no source defines.
  defp compiler_origin(%{name: name, arity: arity}) do
    case {Atom.to_string(name), arity} do
      {"module_info", a} when a in [0, 1] ->
        %{generated_by: "the compiler"}

      {"__info__", 1} ->
        %{generated_by: "the Elixir compiler"}

      {"-inlined-" <> _, _} ->
        %{generated_by: "the compiler (an inlined function)"}

      {other, _} ->
        if Regex.match?(~r/-fun-\d+-$/, other), do: %{generated_by: "fn in its parent"}
    end
  end

  # Without debug info: the file of the function's first line. Code from
  # another file than the module's came from a macro (Elixir) or an
  # include file (Erlang).
  defp line_origin(%{lines: []}, _source), do: %{}

  # Without the module's own source path, which file is the module's is
  # for the reader to tell: their project's file, not a library's.
  defp line_origin(%{lines: [{file, line} | _] = lines}, nil) do
    other = lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> List.delete(file)

    %{defined_at: "#{file}:#{line}"}
    |> then(&if other == [], do: &1, else: Map.put(&1, :includes_code_from, other))
  end

  defp line_origin(%{lines: [{file, line} | _] = lines}, source) do
    files = lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    if same_file?(file, source) do
      other = Enum.reject(files, &same_file?(&1, source))

      %{written_at: "#{file}:#{line}"}
      |> then(&if other == [], do: &1, else: Map.put(&1, :includes_code_from, other))
    else
      %{
        generated_from: "#{file}:#{line}",
        note: "code from another file: a macro or an include file"
      }
    end
  end

  defp same_file?(a, b), do: a == b or (Path.basename(a) == Path.basename(b) and suffix?(a, b))
  defp suffix?(a, b), do: String.ends_with?(a, b) or String.ends_with?(b, a)

  @doc """
  The function named `name` (and `arity`, or every arity), as code:
  Elixir after macro expansion, Erlang, or else BEAM assembly with source
  lines.
  """
  def code(info, name, arity) do
    matching =
      Enum.filter(
        info.functions,
        &named?(&1, name, arity)
      )

    case matching do
      [] ->
        {:error, "#{inspect(info.module)} has no function #{name}#{if arity, do: "/#{arity}"}"}

      functions ->
        {:ok, Enum.map(functions, &render(info, &1))}
    end
  end

  @macro_note "A macro's code after expansion is the code that builds what it returns: its " <>
                "quote is expanded into the tuples it constructs. What it generates is easier to " <>
                "read in the functions it generated: module_code on the module that calls it."

  defp render(%{debug_info: :elixir, defs: defs} = info, f) do
    case Enum.find(defs.definitions, fn {fa, _, _, _} -> fa == def_key(f) end) do
      {{name, _arity}, kind, _meta, clauses} ->
        %{
          function: label(f),
          language: "elixir",
          code: elixir_code(kind, name, clauses)
        }
        |> then(
          &if kind in [:defmacro, :defmacrop], do: Map.put(&1, :note, @macro_note), else: &1
        )

      nil ->
        assembly(info, f)
    end
  end

  defp render(%{debug_info: :erlang, defs: %{forms: forms}} = info, f) do
    case Enum.find(
           forms,
           &match?({:function, _, name, arity, _} when name == f.name and arity == f.arity, &1)
         ) do
      nil ->
        assembly(info, f)

      form ->
        %{
          function: label(f),
          language: "erlang",
          code: form |> :erl_pp.function() |> to_string()
        }
    end
  end

  defp render(info, f), do: assembly(info, f)

  # The head is formatted here: Macro.to_string would print a last
  # argument like a macro's [do: block] as a do block around the head.
  defp elixir_code(kind, name, clauses) do
    Enum.map_join(clauses, "\n\n", fn {_meta, args, guards, body} ->
      when_ = Enum.map_join(guards, "", &(" when " <> Macro.to_string(&1)))
      body = body |> Macro.to_string() |> String.replace(~r/^(?=.)/m, "  ")
      "#{kind} #{name}(#{Enum.map_join(args, ", ", &Macro.to_string/1)})#{when_} do\n#{body}\nend"
    end)
  end

  @max_instructions 150

  # Without debug info: BEAM assembly, its line instructions replaced by
  # the source lines they stand for.
  defp assembly(%{disassembled: :no}, f) do
    %{
      function: label(f),
      language: "none",
      code:
        "unavailable: the .beam has no debug info, and neither this server nor the node could " <>
          "disassemble it (the node runs a newer OTP than this server and has no compiler application)"
    }
  end

  defp assembly(_info, f) do
    shown =
      f.instrs
      |> Enum.take(@max_instructions)
      |> Enum.map(fn
        {:line, {file, line}} -> "  % #{file}:#{line}"
        {:line, :none} -> nil
        instr -> "    " <> inspect(instr, limit: 20, printable_limit: 80)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    more = length(f.instrs) - @max_instructions

    %{
      function: label(f),
      language: "beam assembly (the .beam has no debug info)",
      code: if(more > 0, do: shown <> "\n    … #{more} more instructions", else: shown)
    }
  end

  @doc """
  The functions whose code includes `file`:`line`, as a stack frame names
  it. The file matches by its end, so `gen_server.ex` matches
  `/home/runner/work/elixir/elixir/lib/elixir/lib/gen_server.ex`.
  """
  def at(info, file, line) do
    for f <- info.functions,
        Enum.any?(f.lines, fn {lf, ll} ->
          ll == line and
            (lf == file or String.ends_with?(lf, "/" <> file) or String.ends_with?(file, lf))
        end),
        do: f
  end

  # A line instruction holds an index into the line table (0: none), or,
  # from a newer OTP's beam_disasm (run on the target), the location
  # itself. The first in a function is where it's defined.
  defp resolve_line({:line, i}, table, _own)
       when is_integer(i) and i > 0 and i <= tuple_size(table),
       do: {:line, elem(table, i - 1)}

  defp resolve_line({:line, [{:location, file, line}]}, _table, own),
    do: {:line, {if(file == [] or file == "", do: own, else: to_string(file)), line}}

  defp resolve_line({:line, _}, _table, _own), do: {:line, :none}
  defp resolve_line(instr, _table, _own), do: instr

  @doc """
  The .beam's line table: `{file, line}` for each line instruction's
  index. `beam_lib` doesn't decode it, so this does, from the format
  `beam_asm` writes: a header, the items as compact terms (an atom tag
  switches to another file, an integer is a line), then the file names.
  """
  def line_table(bin) do
    case :beam_lib.chunks(bin, [~c"Line"]) do
      {:ok, {_, [{~c"Line", chunk}]}} -> decode_lines(chunk)
      _ -> []
    end
  end

  @doc false
  def decode_lines(
        <<_version::32, _flags::32, _instrs::32, n_items::32, n_files::32, rest::binary>>
      ) do
    {items, rest} = line_items(rest, n_items, 0, [])
    files = file_names(rest, n_files, [])

    Enum.map(items, fn {index, line} ->
      file = if index == 0, do: "", else: Enum.at(files, index - 1, "")
      {file, line}
    end)
  end

  def decode_lines(_), do: []

  defp line_items(rest, 0, _file, acc), do: {Enum.reverse(acc), rest}

  defp line_items(rest, n, file, acc) do
    case compact_term(rest) do
      {:atom, index, rest} -> line_items(rest, n, index, acc)
      {:integer, line, rest} -> line_items(rest, n - 1, file, [{file, line} | acc])
    end
  end

  defp file_names(_rest, 0, acc), do: Enum.reverse(acc)

  defp file_names(<<size::16, name::binary-size(size), rest::binary>>, n, acc),
    do: file_names(rest, n - 1, [name | acc])

  import Bitwise

  # A compact term: tag in the low 3 bits; a value below 16 in the high
  # 4, below 2048 in the high 3 and the next byte, or else in the next
  # 2 to 8 bytes.
  defp compact_term(<<b, rest::binary>>) do
    tag = if (b &&& 7) == 2, do: :atom, else: :integer

    cond do
      (b &&& 0x08) == 0 ->
        {tag, b >>> 4, rest}

      (b &&& 0x10) == 0 ->
        <<low, rest::binary>> = rest
        {tag, (b >>> 5) <<< 8 ||| low, rest}

      true ->
        size = (b >>> 5) + 2
        <<value::size(size * 8), rest::binary>> = rest
        {tag, value, rest}
    end
  end
end
