defmodule OtpDebugMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :otp_debug_mcp,
      version: "0.10.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      otp_debug_mcp: [
        include_executables_for: [:unix],
        # Keep debug_info: recon is compiled from it on targets running an
        # older OTP release, which can't load our compiled code.
        strip_beams: [keep: ["Dbgi"]]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
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
      {:recon, "~> 2.5"},
      # Only so tests can run a Bandit, Cowboy or Yaws server, shackle
      # client pools, and a riak_core cluster with riak_dt's CRDTs, on
      # target nodes.
      {:bandit, "~> 1.13", only: :test},
      {:cowboy, "~> 2.12", only: :test},
      {:cowboy_telemetry, "~> 0.4", only: :test},
      # Yaws isn't on Hex; its build compiles a PAM driver (libpam0g-dev on
      # Debian and Ubuntu).
      {:yaws,
       github: "erlyaws/yaws", tag: "yaws-2.3.1", only: :test, runtime: false, manager: :rebar3},
      {:shackle, "~> 0.8.0", only: :test, runtime: false},
      {:riak_core, "~> 0.11.1", hex: :riak_core_lite, only: :test, runtime: false},
      {:riak_dt, "~> 2.1", only: :test, runtime: false}
    ]
  end
end
