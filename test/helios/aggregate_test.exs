defmodule Helios.AggregateTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Helios.Integration.Assertions
  alias Helios.Integration.UserAggregate
  alias Helios.Integration.Events.UserCreated
  alias Helios.Integration.Events.UserEmailChanged
  alias Helios.Pipeline.Context
  alias Helios.EventJournal.Messages.EventData

  doctest Helios.Aggregate

  @correlation_id UUID.uuid4()

  setup do
    ctx = %Context{
      aggregate: %UserAggregate{},
      aggregate_module: UserAggregate,
      correlation_id: @correlation_id,
      peer: self()
    }

    [ctx: ctx]
  end

  test "should execute logger in aggregate pipeline", args do
    ctx_before = %{
      args.ctx
      | command: :create_user,
        params: %{id: 1, first_name: "Jhon", last_name: "Doe", email: "jhon.doe@gmail.com"}
    }

    assert [] == UserAggregate.init([])
    metadata = %{correlation_id: @correlation_id}

    assert(
      capture_log(fn ->
        ctx_after = UserAggregate.call(ctx_before, :create_user)

        expected = [
          %EventData{
            data: %UserCreated{
              first_name: "Jhon",
              last_name: "Doe",
              user_id: 1
            },
            metadata: metadata,
            type: "Elixir.Helios.Integration.Events.UserCreated"
          },
          %EventData{
            data: %UserEmailChanged{
              new_email: "jhon.doe@gmail.com",
              old_email: nil,
              user_id: 1
            },
            metadata: metadata,
            type: "Elixir.Helios.Integration.Events.UserEmailChanged"
          }
        ]

        assert_emitted(ctx_after, expected)

        # assert ^expected = ctx_after.events

        assert_halted(ctx_after, false)
        assert_response(ctx_after, :created)
      end) =~ "Executing command create_user on aggregate #{UserAggregate}"
    )
  end
end