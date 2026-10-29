defmodule TelemetryShop.MixProject do
  use Mix.Project

  def project do
    [
      app: :telemetry_shop,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:telemetry, "~> 1.2"}]
    ]
  end

  def application do
    [mod: {Shop.Application, []}, extra_applications: [:logger]]
  end
end
