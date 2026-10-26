defmodule BanditShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:bandit, "~> 1.13"}]
    ]
  end

  def application do
    [mod: {BanditShop.Application, []}, extra_applications: [:logger]]
  end
end
