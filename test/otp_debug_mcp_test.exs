defmodule OtpDebugMcpTest do
  use ExUnit.Case
  doctest OtpDebugMcp

  test "greets the world" do
    assert OtpDebugMcp.hello() == :world
  end
end
