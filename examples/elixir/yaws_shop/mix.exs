defmodule YawsShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :yaws_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      # Yaws isn't on Hex. Its build compiles a PAM driver: on Debian and
      # Ubuntu, install libpam0g-dev first. Not started by Mix: the shop
      # starts it embedded, with its own configuration.
      deps: [
        {:yaws, github: "erlyaws/yaws", tag: "yaws-2.3.1", manager: :rebar3, runtime: false}
      ]
    ]
  end

  def application do
    [mod: {:yaws_shop, []}, extra_applications: [:logger, :crypto]]
  end
end
