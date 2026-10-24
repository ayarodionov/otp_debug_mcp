defmodule PhoenixShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {PhoenixShop.Application, []}, extra_applications: [:logger, :inets]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.13"},
      {:jason, "~> 1.4"}
    ]
  end
end
