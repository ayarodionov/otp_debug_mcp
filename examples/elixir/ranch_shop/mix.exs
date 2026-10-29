defmodule RanchShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :ranch_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:ranch, "~> 2.1"}]
    ]
  end

  def application do
    [mod: {:ranch_shop, []}, extra_applications: [:logger]]
  end
end
