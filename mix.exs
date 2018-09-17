defmodule Helios.MixProject do
  use Mix.Project

  @version "0.1.0"
  @journal_adapters [:eventstore]

  def project do
    [
      app: :helios,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      test_paths: test_paths(Mix.env()),
      build_per_environment: false,
      deps: deps(),
      # Hex
      description: "A building blocks for CQRS segregated applications",
      package: package(),
      name: "Helios",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Helios, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:helios_aggregate, path: "../helios_aggregate"},
      {:extreme, github: "exponentially/extreme", branch: "master", optinal: true}
    ]
  end

  defp test_paths(journal_adapter) when journal_adapter in @journal_adapters,
    do: ["integration_test/#{journal_adapter}"]

  defp test_paths(_), do: ["test/helios"]

  defp package() do
    [
      maintainers: ["Milan Jarić"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/exponentially/helios"},
      files:
        ~w(.formatter.exs mix.exs README.md CHANGELOG.md lib) ++
          ~w(integration_test/cases integration_test/support)
    ]
  end

  defp docs() do
    [
      main: "Ecto",
      source_ref: "v#{@version}",
      canonical: "http://hexdocs.pm/ecto",
      logo: "guides/images/e.png",
      source_url: "https://github.com/elixir-ecto/ecto",
      extras: [
        "guides/Getting Started.md",
        "guides/Associations.md",
        "guides/Testing with Ecto.md"
      ],
      groups_for_modules: []
    ]
  end
end
