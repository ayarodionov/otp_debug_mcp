defmodule PostgrexShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :postgrex_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:postgrex, "~> 0.22.4"}]
    ]
  end

  def application do
    [mod: {Shop.Application, []}, extra_applications: [:logger]]
  end
end
