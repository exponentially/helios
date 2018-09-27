# Your First Aggregate

To build first aggregate, you need to implement `Helios.Aggregate` behaviour that 
providies extendable facility for aggregate command pipeline.

## Helios Installation

[Available in Hex](https://hex.pm/packages/helios_aggregate), the package can be installed
by adding `helios_aggregate` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:helios, "~> 0.1"}
  ]
end
```

## Defining Domain Events

```elixir
defmodule CustomerCreated do
  defstruct [:customer_id, :first_name, :last_name]
end

defmodule CustomerContactCreated do
  defstruct [:customer_id, :email]
end
```

## Customer Aggregate Example

```elixir
defmodule CustomerAggregate do
  use Helios.Aggregate

  # Aggregate state
  defstruct [:id, :first_name, :last_name, :email]

  def create_customer(ctx, %{id: id, first_name: fname, last_name: lname, email: email}) do
    if id == ctx.aggregate.id do
      raise RuntimeError, "Already created"
    end

    ctx
    |> emit(%CustomerCreated{
        customer_id: id,
        first_name: fname,
        last_name: lname
      })
    |> emit(%CustomerContactCreated{
        customer_id: id,
        email: email
      })
    |> ok(%{status: :created, payload: %{id: id}})
  end

  def apply_event(%CustomerCreated{}=event, customer) do
    %{customer
      | id: event.id,
        first_name: event.first_name,
        last_name: event.last_name
    }
  end

  def apply_event(%CustomerContactCreated{email: email}, customer) do
    %{customer| email: email}
  end

  # sometimes we generate event but it is not needed in recovery and it is safe to
  # skip it
  def apply_event(_, agg), do: agg
end
```

## Message Handler Sample Code

```elixir
  
  ctx = %Helios.Context{
    aggregate: %CustomerAggregate{},
    aggregate_module: CustomerAggregate,
    correlation_id: "1234567890",
    command: :create_customer,
    peer: self(),
    params: %{first_name: "Jhon", last_name: "Doe", email: "jhon.doe@gmail.com"}
  }

  ctx = Cusomer.call(ctx, :create_customer)
    
```

## Pipeline Logger configuration

We built logger which should log each command sent to aggregate. Since commands 
can cary some confidential information, or you have to be PCI DSS compliant, 
we expsed configuration like below where you could configure which filed values
in command should be retracted.

Below is example where list of field names are given. Please note, the logger
plug will not try to conver string to atom or other way round, if you have both 
case please state them in list as both, string and atom.
```elixir
use Mix.Config

# filter only specified
config :helios, 
  :filter_parameters, [:password, "password", :credit_card_number]

# filter all but keep original values
config :helios, 
  :filter_parameters, {:keep, [:email, "email", :full_name]}

# retract only specified field values
config :helios, 
  :filter_parameters, [:password, "password", :credit_card_number]


```