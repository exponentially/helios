defmodule Helios.MixProject do
  use Mix.Project

  @version "0.2.0"
  @journal_adapters ["eventstore"]

  def project do
    [
      app: :helios,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      test_paths: test_paths(System.get_env("JOURNAL_ADAPTER")),
      build_per_environment: false,
      deps: deps(),

      aliases: ["test.all": ["test", "test.adapters"],
               "test.adapters": &test_adapters/1],

      # Hex
      description: "A building blocks for CQRS segregated applications",
      package: package(),
      name: "Helios",
      docs: docs(),
      dialyzer: [ plt_add_apps: [:mix] ,
                  ignore_warnings: ".dialyzer_ignore.exs",
                  list_unused_filters: true
                ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Helios, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: [:test, :dev]},
      {:elixir_uuid, "~> 1.2"},
      {:libring, "~> 1.0"},
      {:gen_state_machine, "~> 2.0"},
      {:extreme, "~> 0.13", optinal: true},
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev, :test], runtime: false, optinal: true},
      {:credo, "~> 0.10.0", only: [:dev, :test], runtime: false},
      {:poolboy, "~> 1.5"}
    ]
  end

  defp test_paths(journal_adapter) when journal_adapter in @journal_adapters,
    do: ["integration_test/#{journal_adapter}"]

  defp test_paths(_), do: ["test/helios"]

  defp test_adapters(args) do
    for env <- @journal_adapters, do: test_run(env, args)
  end

  defp test_run(adapter, args) do
    args = if IO.ANSI.enabled?, do: ["--color"|args], else: ["--no-color"|args]

    IO.puts "==> Running tests for adapter #{adapter} mix test"
    {_, res} = System.cmd "mix", ["test" | args],
                          into: IO.binstream(:stdio, :line),
                          env: [{"MIX_ENV", "test"}, {"JOURNAL_ADAPTER", adapter}]

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp package() do
    [
      maintainers: ["Milan Jarić"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/exponentially/helios"},
      files:
        ~w(.formatter.exs mix.exs README.md CHANGELOG.md lib) ++
          ~w(integration_test/support)
    ]
  end

  defp docs() do
    [
      main: "your-first-aggregate",
      source_ref: "v#{@version}",
      canonical: "http://hexdocs.pm/helios",
      # logo: "guides/images/e.png",
      source_url: "https://github.com/exponentially/helios",
      extras: [
        "guides/Your First Aggregate.md",
        "guides/Configuration.md",
        "guides/Routing.md"
      ],
      groups_for_modules: [
        "Aggregate": [
          Helios.Aggregate,
          Helios.Aggregate.Server,
          Helios.Aggregate.Supervisor
        ],
        "Pipeline": [
          Helios.Context,
          Helios.Pipeline,
          Helios.Pipeline.Adapter,
          Helios.Pipeline.Builder,
          Helios.Pipeline.Plug,
          Helios.Plugs.Logger
        ],
        "Event Journal": [
          Helios.EventJournal,
          Helios.EventJournal.Adapter,
          Helios.EventJournal.Messages.EventData,
          Helios.EventJournal.Messages.PersistedEvent,
          Helios.EventJournal.Messages.Position,
          Helios.EventJournal.Messages.ReadAllEventsResponse,
          Helios.EventJournal.Messages.ReadStreamEventsResponse,
          Helios.EventJournal.Messages.StreamMetadataResponse,
        ],
        "Testing": [
          Helios.Pipeline.Test,
        ],
        "Endpoint": [
          Helios.Endpoint,
          Helios.Endpoint.Facade,
          Helios.Endpoint.Supervisor,

        ]
      ]
    ]
  end
end
