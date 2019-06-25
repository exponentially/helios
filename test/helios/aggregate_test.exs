defmodule Helios.AggregateTest do
  use ExUnit.Case, async: true
  alias Helios.Integration.UserAggregate
  alias Helios.Context

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
    request_id = UUID.uuid4()
    params = %{
      "id" => 1,
      "first_name" => "Jhon",
      "last_name" => "Doe",
      "email" => "jhon.doe@gmail.com"
    }

    {:ok, aggregate} = UserAggregate.init([id: 1234, otp_app: :dummy_app])

    ctx_before =
      args.ctx
      |> Map.put(:request_id, request_id)
      |> Map.put(:params, params)
      |> Context.assign(:aggregate, aggregate)
      |> Context.put_private(:helios_plug_key, "id")
      |> Context.put_private(:helios_plug_handler, :create_user)



    ctx_after = UserAggregate.handle(ctx_before, params)

    assert not ctx_after.halted


    assert 2 == Enum.count(ctx_after.events)
    assert [e1, e2] = ctx_after.events

    assert e1.data.first_name == "Jhon"
    assert e1.data.last_name == "Doe"
    assert e1.data.user_id == 1
    assert e1.type == "Elixir.Helios.Integration.Events.UserCreated"
    assert e1.metadata.causation_id == request_id

    assert e2.data.new_email == "jhon.doe@gmail.com"
    assert e2.data.old_email == nil
    assert e2.data.user_id == 1
    assert e2.type == "Elixir.Helios.Integration.Events.UserEmailChanged"
    assert e2.metadata.causation_id == request_id

    assert :set == ctx_after.state
    assert ctx_after.response == :created
  end
end
