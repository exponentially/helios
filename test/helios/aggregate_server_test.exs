defmodule Helios.AggregateServerTest do
  use ExUnit.Case, async: true
  alias Helios.Aggregate.Server
  alias Helios.Context
  alias Helios.Integration.UserAggregate
  alias Helios.Integration.Events.UserCreated
  alias Helios.Integration.Events.UserEmailChanged
  alias Helios.Integration.TestJournal

  use Helios.Pipeline.Test

  defmodule Endpoint do
    use Helios.Endpoint, otp_app: :helios
  end

  setup do
    id = UUID.uuid4()
    {:ok, pid} = Server.start_link(:helios, {UserAggregate, id})

    stream_name = UserAggregate.persistance_id(id)

    [
      id: id,
      pid: pid,
      stream_name: stream_name
    ]
  end

  @tag :aggregate_server
  test "should persist UserCreated in event journal", args do
    # Task.start(fn -> :sys.trace(pid, true) end)

    params = %{"id" => 1, "first_name" => "Jhon", "last_name" => "Doe", "email" => "jhon.doe@gmail.com"}
    path = "/users/#{args.id}/create_user"

    ctx =
      ctx(:execute, path, params)
      |> Context.put_private(:helios_plug, UserAggregate)
      |> Context.put_private(:helios_plug_key, args.id)
      |> Context.put_private(:helios_plug_handler, :create_user)


    assert %Context{} = GenServer.call(args.pid, {:execute, ctx})

    assert {:ok,
            %{
              events: [
                %{data: %{__struct__: UserCreated}},
                %{data: %{__struct__: UserEmailChanged}}
              ]
            }} = TestJournal.read_stream_events_forward(args.stream_name, -1, 2)

    GenServer.stop(args.pid)
  end
end
