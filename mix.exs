defmodule OtpDebugMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :otp_debug_mcp,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      otp_debug_mcp: [include_executables_for: [:unix]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {OtpDebugMcp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # MCP server framework (stdio + streamable HTTP transports).
      {:anubis_mcp, "~> 2.1"},
      # Production-safe BEAM introspection. Loaded locally; its object code is
      # injected into the target node at connect time (see OtpDebugMcp.Target),
      # so the target app needs no recon dependency of its own.
      {:recon, "~> 2.5"}
    ]
  end
end
