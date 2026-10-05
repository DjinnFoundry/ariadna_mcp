defmodule AriadnaMCP.MixProject do
  use Mix.Project

  @version "0.2.2"
  @source_url "https://github.com/DjinnFoundry/ariadna_mcp"

  def project do
    [
      app: :ariadna_mcp,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Stateless Model Context Protocol servers for Plug and Phoenix.",
      source_url: @source_url,
      docs: [main: "AriadnaMCP", source_ref: "v#{@version}"],
      dialyzer: [plt_add_apps: [:mix, :ex_unit], flags: [:error_handling, :underspecs]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:peri, "~> 0.9.0"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:jido_action, "~> 2.3", optional: true},
      {:ex_mcp, "~> 1.5", only: :test},
      {:bandit, "~> 1.12", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
