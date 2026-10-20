defmodule OtpDebugMcp.TlsDistTest do
  @moduledoc """
  Runs when the whole suite runs over TLS distribution, which peers inherit
  through ERL_FLAGS:

      CONF=$(scripts/tls_dist_certs.sh /tmp/tls)
      ERL_FLAGS="-proto_dist inet_tls -ssl_dist_optfile $CONF" mix test
  """
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, TestTarget}

  @moduletag :tls_dist

  test "the target sees our connection as TLS" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)

    # #net_address{address, host, protocol, family}
    {:ok, protocols} =
      Checks.remote_eval("""
      {ok, Info} = net_kernel:nodes_info(),
      [element(4, proplists:get_value(address, I)) || {_, I} <- Info].
      """)

    assert protocols == [:tls]
  end
end
