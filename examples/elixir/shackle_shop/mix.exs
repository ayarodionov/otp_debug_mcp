defmodule ShackleShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :shackle_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:shackle, "~> 0.8.0"}]
    ]
  end

  def application do
    [mod: {:shackle_shop, []}, extra_applications: [:logger]]
  end
end
