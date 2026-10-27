defmodule RiakShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :riak_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:riak_core, "~> 0.11.1", hex: :riak_core_lite}, {:riak_dt, "~> 2.1"}]
    ]
  end

  def application do
    [mod: {:riak_shop, []}, extra_applications: [:logger]]
  end
end
