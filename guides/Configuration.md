# Helios Configuration

Below are defaults that are used. You can override any of this configuration in your aplication.

## Global Helios Configuration

Default journal to use in any endpoint started in application
```elixir
config :helios, :default_journal, MyApp.DefaultJournal
```

The way plugs are added in piepeline
* `:compile` - during application compilation (cannot be changed later)
* `:runtime` - during runtime, before pipeline is executed

```elixir
config :helios, :plug_init_mode, :compile
```

Tell endpoint to start aggregates supervison tree in endpoint.

Supported values are:
 * `true` - run aggregates on local node
 * `false` - don't run any aggregates on local node

NOTE: Proxying is not yet done

```elixir
config :helios, :serve_endpoints, true
```

While aggregate command is executing, in some places there are default loggers that will log parameters sent in command, to avoid disclosure of values use filters

Retract only specified field values
```elixir
config :helios, :filter_parameters, 
  [:password, "password", :credit_card_number]

```

Retract all values except for specified keys
```elixir
config :helios, :filter_parameters, 
  {:keep, [:email, "email", :full_name]}
```

Then, some log levels can be suppresed by configuring how verbose helios should be

Valid values are:
* `:debug` - includes debug, info, warn and error messages
* `:info` - includes info, wanrn and error messages
* `:warn` - only want and error messages
* `:error` - only reder error messages

```elixir
config :helios, :log_level, :debug
```

## EventJournal Configuration

Each journal need adpater, so please either use built in or create 
yours by implementing `Helios.EventJounral.Adapter` behaviour

If you need to test your aggregates, below should be best adater 
configuration for such case

```elixir
config :my_app, MyApp.Journals.UserJournal,
  adapter: Helios.EventJournal.Adapter.Memory
  addater_config: []
```

For production, use `Helios.EventJournal.Adapter.Eventstore` or 
create your implementation of `Helios.EventJounral.Adapter` 
behaviour. To use eventstore builtin adapter you need to include 
`{:extreme, "~> 0.13"}` in deps in your `mix.exs` file and then compile again helios 

in mix.exs file
```elixir

 
  # ...snip...

  def application do
    [
      extra_applications: [:logger, :extreme, :helios],
      mod: {MyApp, []}
    ]
  end

  def deps do
    [
      {:extreme, "~> 0.13"},
      {:helios, "~> 0.1"},
      # ... other deps ...
    ]
  end

  # ...end_snip...
```

in bash shell

```bash
$ mix deps.compile helios
```

in config/prod.exs
```elixir
config :my_app, MyApp.Journals.UserJournal,
  adapter: Helios.EventJournal.Adapter.Eventstore
  addater_config: [
    db_type: :node,
    host: "localhost",
    port: 1113,
    username: "admin",
    password: "changeit",
    connection_name: "my_app",
    max_attempts: 10
  ]
```

## Helios Endpoint specific configuration


```elixir
config :my_app, MyApp.Endpoint,
  [
    journal: MyApp.OtherJournal 
    registry: [
      sync_nodes_timeout: 5_000,
      strategy: Helios.Registry.Strategy.Ring
    ] 

  ]
```