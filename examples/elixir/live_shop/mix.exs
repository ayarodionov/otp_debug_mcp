defmodule LiveShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [mod: {LiveShop.Application, []}, extra_applications: [:logger, :inets]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:bandit, "~> 1.13"},
      {:jason, "~> 1.4"}
    ]
  end
end
