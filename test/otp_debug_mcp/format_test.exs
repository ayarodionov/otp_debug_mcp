defmodule OtpDebugMcp.FormatTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Format, TestTarget}

  setup_all do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    pid = TestTarget.call(target, :erlang, :whereis, [:init])

    %{
      pid: pid,
      as_target_prints_it: TestTarget.call(target, :erlang, :pid_to_list, [pid]) |> to_string()
    }
  end

  test "prints the target's pids as the target does", %{pid: pid, as_target_prints_it: printed} do
    assert inspect(pid) =~ ~r/^#PID<[1-9]\d*\.\d+\.\d+>$/
    assert printed =~ ~r/^<0\.\d+\.\d+>$/
    assert Format.inspect(pid) == printed
  end

  test "rewrites pids anywhere in a term", %{pid: pid, as_target_prints_it: printed} do
    term = %{list: [pid | pid], tuple: {:ok, pid}, struct: %URI{host: pid}, key: %{pid => 1}}
    out = Format.inspect(term)
    refute out =~ "#PID"
    assert length(String.split(out, printed)) - 1 == 5
  end

  test "prints the target's ports as the target does", %{target: target} do
    [port | _] = TestTarget.call(target, :erlang, :ports, [])
    printed = TestTarget.call(target, :erlang, :port_to_list, [port]) |> to_string()
    assert printed =~ ~r/^#Port<0\.\d+>$/
    assert Format.inspect(port) == printed
  end

  test "names the node of pids that aren't the target's" do
    assert Format.inspect(self()) =~ ~r/^<#{Regex.escape(Atom.to_string(node()))}\.\d+\.\d+>$/
  end

  test "prints a plain Erlang node's terms in Erlang syntax" do
    target = TestTarget.start(erlang: true)
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    pid = TestTarget.call(target, :erlang, :whereis, [:init])
    printed = TestTarget.call(target, :erlang, :pid_to_list, [pid]) |> to_string()

    assert Format.inspect(%{name: :init, pid: pid, text: "hi", list: [1, {:ok, pid}]}) ==
             "\#{list => [1,{ok,#{printed}}],name => init,pid => #{printed},text => <<\"hi\">>}"

    assert Format.inspect(:price_cache) == "price_cache"
  end

  test "formats Erlang terms on the target", %{pid: pid, as_target_prints_it: printed} do
    assert Format.erlang(~c"~p", [{pid, :ok}]) == "{#{printed},ok}"
  end
end
