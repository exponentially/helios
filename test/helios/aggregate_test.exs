defmodule Helios.AggregateTest do
  use ExUnit.Case, async: true
  import Helios.Integration.Assertions
  alias Helios.Integration.UserAggregate
  alias Helios.Integration.Events.UserCreated
  alias Helios.Integration.Events.UserEmailChanged
  alias Helios.Context
  alias Helios.EventJournal.Messages.EventData

  doctest Helios.Aggregate

  setup do
    ctx = %Context{
      peer: self(),
      private: %{
        helios_plug: UserAggregate
      }
    }

    [ctx: ctx]
  end

  test "should execute logger in aggregate pipeline", args do
    params = %{
      "id" => 1,
      "first_name" => "Jhon",
      "last_name" => "Doe",
      "email" => "jhon.doe@gmail.com"
    }

    ctx_before =
      args.ctx
      |> Map.put(:request_id, UUID.uuid4())
      |> Map.put(:params, params)
      |> Context.assign(:aggregate, UserAggregate.new())
      |> Context.put_private(:helios_plug_key, "id")
      |> Context.put_private(:helios_plug_handler, :create_user)



    ctx_after = UserAggregate.handle(ctx_before, params)

    expected = [
      %EventData{
        data: %UserCreated{
          first_name: "Jhon",
          last_name: "Doe",
          user_id: 1
        },
        type: "Elixir.Helios.Integration.Events.UserCreated"
      },
      %EventData{
        data: %UserEmailChanged{
          new_email: "jhon.doe@gmail.com",
          old_email: nil,
          user_id: 1
        },
        type: "Elixir.Helios.Integration.Events.UserEmailChanged"
      }
    ]

    assert_emitted(ctx_after, expected)
    assert_halted(ctx_after, false)
    assert_response(ctx_after, :created)
  end
end
