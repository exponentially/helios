defmodule Helios.AggregateServerTest do
  use ExUnit.Case, async: true
  alias Helios.Aggregate.Server
  alias Helios.Pipeline.Context
  alias Helios.Integration.UserAggregate
  alias Helios.Integration.Events.UserCreated
  alias Helios.Integration.Events.UserEmailChanged
  alias Helios.Integration.TestJournal

  @tag :aggregate_server
  test "should persist UserCreated in event journal" do
    module = UserAggregate
    id = UUID.uuid4()
    {:ok, pid} = Server.start_link(:helios, {module, id})

    stream_name = module.persistance_id(id)
    assert "users-" <> _ = stream_name

    ctx = %Context{
      request_id: UUID.uuid4(),
      aggregate_module: UserAggregate,
      command: :create_user,
      params: %{id: id, first_name: "Jhon", last_name: "Doe", email: "jhon.doe@gmail.com"},
      owner: self()
    }

    assert {:ok, :created} = Server.call(pid, ctx)

    assert {:ok,
            %{
              events: [
                %{data: %{__struct__: UserCreated}},
                %{data: %{__struct__: UserEmailChanged}}
              ]
            }} = TestJournal.read_stream_events_forward(stream_name, -1, 2)

  end
end
