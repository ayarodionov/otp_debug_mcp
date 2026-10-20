defmodule OtpDebugMcp.TargetTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Target, TestTarget}
  alias OtpDebugMcp.Fixtures.{Operator, Ticker}

  defp start_target(opts \\ []) do
    target = TestTarget.start(opts)
    on_exit(fn -> TestTarget.stop(target) end)
    target
  end

  describe "connect" do
    test "attaches as a hidden node" do
      target = start_target()

      assert {:ok, _} = TestTarget.connect(target)
      assert target.node in Node.list(:hidden)
      assert {:ok, []} = Target.rpc(:erlang, :nodes, [])
    end

    test "without a cookie argument, uses OTP_DEBUG_MCP_COOKIE" do
      target = start_target()
      System.put_env("OTP_DEBUG_MCP_COOKIE", target.cookie)
      on_exit(fn -> System.delete_env("OTP_DEBUG_MCP_COOKIE") end)

      assert {:ok, _} = Target.connect(Atom.to_string(target.node), nil)
    end

    test "our own node's cookie is random, not ~/.erlang.cookie" do
      target = start_target()
      {:ok, _} = TestTarget.connect(target)

      ours = Atom.to_string(Node.get_cookie())
      assert byte_size(ours) >= 32

      case File.read(Path.join(System.user_home!(), ".erlang.cookie")) do
        {:ok, home} -> assert String.trim(home) != ours
        {:error, _} -> :ok
      end

      # The target's own cookie is set for it alone.
      assert :erlang.get_cookie(target.node) == String.to_atom(target.cookie)
    end

    test "fails with a wrong cookie" do
      target = start_target()

      assert {:error, :connection_failed} =
               Target.connect(Atom.to_string(target.node), "wrong_cookie")
    end

    test "switches between shortnames and longnames targets" do
      long = start_target(longnames: true)
      short = start_target()

      assert {:ok, _} = TestTarget.connect(long)
      assert {:ok, long.node} == Target.rpc(:erlang, :node, [])

      assert {:ok, _} = TestTarget.connect(short)
      assert {:ok, short.node} == Target.rpc(:erlang, :node, [])

      assert {:ok, _} = TestTarget.connect(long)
      assert {:ok, long.node} == Target.rpc(:erlang, :node, [])
    end

    test "reconnects and re-injects recon after the target restarts" do
      target = TestTarget.start()
      {:ok, _} = TestTarget.connect(target)

      target = TestTarget.restart(target)
      on_exit(fn -> TestTarget.stop(target) end)

      assert {:ok, [_ | _]} = Target.rpc(:recon, :proc_count, [:memory, 3])
    end

    test "reports a lost connection" do
      target = TestTarget.start()
      {:ok, _} = TestTarget.connect(target)
      TestTarget.stop(target)

      assert {:error, {:connection_lost, node}} = Target.rpc(:erlang, :node, [])
      assert node == target.node
    end
  end

  describe "recon injection" do
    test "injects recon into a target without it" do
      target = start_target()

      assert {:ok, %{recon: %{source: "injected", version: _}}} = TestTarget.connect(target)
      assert {:ok, [_ | _]} = Target.rpc(:recon, :proc_count, [:memory, 3])
    end

    test "a repeat connect loads nothing and still recognizes our copy" do
      target = start_target()
      {:ok, _} = TestTarget.connect(target)

      assert {:ok, %{recon: %{source: "injected"}}} = TestTarget.connect(target)
      # Loading again would have left the first copy as old code.
      assert {:ok, false} = Target.rpc(:erlang, :check_old_code, [:recon])
    end

    test "uses the target's own recon and leaves its trace session running" do
      target = start_target(recon: true)
      {:ok, _} = TestTarget.call(target, Ticker, :start, [:ticker, 100])
      :ok = TestTarget.call(target, Operator, :start, [{Ticker, :handle_info, :_}])

      assert {:ok, %{recon: recon}} = TestTarget.connect(target)
      assert %{source: "target", injected_missing_modules: []} = recon

      Checks.run_all()
      {:ok, _} = TestTarget.connect(target)

      assert TestTarget.call(target, Operator, :alive?, [])
      before = TestTarget.call(target, Operator, :lines, [])
      Process.sleep(300)
      assert TestTarget.call(target, Operator, :lines, []) > before
    end
  end
end
