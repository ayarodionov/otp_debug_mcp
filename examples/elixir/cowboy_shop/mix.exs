defmodule CowboyShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :cowboy_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:cowboy, "~> 2.12"}]
    ]
  end

  def application do
    [mod: {:cowboy_shop, []}, extra_applications: [:logger]]
  end
end
