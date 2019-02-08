# Helios

A building blocks for elixir CQRS segregated applications.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `helios` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:helios, "~> 0.1"}
  ]
end
```

Example application can be seen [here](https://github.com/exponentially/helios_example)

## Configuration

It is important to knwo that there is minimum configuration that has to be explicitly 
configured in your application, without it application will not work or start.

### Default Event Journal
```elixir
use Mix.Config

config :your_app, :default_journal,
  YourApp.DefaultJournal

# you also need to configure that journal
config :your_app, YourApp.DefaultJournal,
  adapter: Helios.EventJournal.Adapter.Memory # ETS journal
  adapter_config: []
```

or, if you need to persist events over application restarts

```elixir
use Mix.Config

config :your_app, :default_journal,
  YourApp.DefaultJournal

config :your_app, YourApp.DefaultJournal,
  adapter: Helios.EventJournal.Adapter.Eventstore
  adapter_config: [
    db_type: :node,
    host: "localhost",
    port: 1113,
    username: "admin",
    password: "changeit",
    connection_name: "your_app",
    max_attempts: 10
  ]
```

don't forget to add [extreme](https://github.com/exponentially/extreme) dependency to
your project `{:extreme, "~> 0.13"}`

## Guides

* [Helios Configuration](guides/Configuration.md)
* [Your First Aggregate Behaviour](guides/Your%20First%20Aggregate.md)
* [Routing](guides/Routing.md)


