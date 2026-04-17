defmodule PhoenixKitComments.MixProject do
  use Mix.Project

  @version "0.1.6"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_comments"

  def project do
    [
      app: :phoenix_kit_comments,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Comments module for PhoenixKit — polymorphic threading, likes/dislikes, and moderation",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitComments",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      {:phoenix_kit, "~> 1.7"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # Giphy API client used by the optional Giphy picker in the comment form.
      {:giphy_api, "~> 0.1.1"},

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitComments",
      source_ref: "v#{@version}"
    ]
  end
end
