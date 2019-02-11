defmodule Helios.Integration.AdapterCasesTest do
  use ExUnit.Case, async: false
  alias Helios.EventJournal.Messages
  alias Helios.Integration.TestJournal, as: Journal
  alias Helios.Integration.Events.UserCreated

  @tag :event_journal
  @tag :event_journal_write
  test "should write to stream in journal and return correct event version" do
    stream = "journal_test_write_stream"

    event =
      Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %{
        first_name: "firstname 1",
        last_name: "lastname 2"
      })

    assert {:ok, 0} == Journal.append_to_stream(stream, [event], -1)
    assert {:ok, 1} == Journal.append_to_stream(stream, [event], 0)
    assert {:ok, 3} == Journal.append_to_stream(stream, [event, event], 1)
  end

  @tag :event_journal
  @tag :event_journal_read_single
  test "should read single event at given position" do
    stream = "journal_test_read_single_event"

    events =
      Enum.map(
        0..3,
        &Messages.EventData.new(
          Extreme.Tools.gen_uuid(),
          UserCreated,
          %UserCreated{first_name: "Test #{&1}", last_name: "Lastname #{&1}"},
          %{emitted_at: DateTime.utc_now()}
        )
      )

    assert {:ok, 3} == Journal.append_to_stream(stream, events, -1)
    {event, _} = List.pop_at(events, 2)

    {:ok, persisted} = Journal.read_event(stream, 2, true)

    assert persisted.stream_id == stream
    assert persisted.event_number == 2
    assert persisted.event_id != nil
    assert persisted.event_type == Atom.to_string(UserCreated)
    assert persisted.data == event.data
    assert %{emitted_at: _} = persisted.metadata
    assert %DateTime{} = persisted.created
  end

  @tag :event_journal
  @tag :event_journal_read
  test "should read events from given stream, from given position, forward" do
    stream = "journal_test_read_forward_stream"
    number_of_events = 20

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, ^number_of_events} = Journal.append_to_stream(stream, events, -1)

    {event_5, _} = List.pop_at(events, 5)
    {event_14, _} = List.pop_at(events, 14)

    {:ok, persisted} = Journal.read_stream_events_forward(stream, 0, 10, true)
    {:ok, persisted} = Journal.read_stream_events_forward(stream, 5, 10, true)

    assert length(persisted.events) == 10
    {first, _} = List.pop_at(persisted.events, 0)
    {last, _} = List.pop_at(persisted.events, 9)
    assert event_5.data == first.data
    assert event_14.data == last.data
  end

  @tag :event_journal
  @tag :event_journal_read
  test "should read events from given stream, from given position, backward" do
    stream = "journal_test_read_stream_backward"
    number_of_events = 20

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, ^number_of_events} = Journal.append_to_stream(stream, events, -1)

    {event_6, _} = List.pop_at(events, 6)
    {event_10, _} = List.pop_at(events, 10)

    {:ok, persisted} = Journal.read_stream_events_backward(stream, 10, 5, true)

    assert length(persisted.events) == 5
    {first, _} = List.pop_at(persisted.events, 0)
    {last, _} = List.pop_at(persisted.events, 4)
    assert event_10.data == first.data
    assert event_6.data == last.data
  end

  @tag :event_journal
  @tag :event_journal_read_all
  test "should read all events from event store forward" do
    stream = "journal_test-#{UUID.uuid4()}"
    number_of_events = 500

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, ^number_of_events} = Journal.append_to_stream(stream, events, -1)

    {:ok, resp} = Journal.read_all_events_forward({0, 0}, 50, true)
    assert length(resp.events) == 50

    {:ok, resp} = Journal.read_all_events_forward({-1, -1}, 50, true)
    assert length(resp.events) == 0

    {:ok, resp} = Journal.read_all_events_backward({0, 0}, 50, true)
    assert length(resp.events) == 0

    {:ok, resp} = Journal.read_all_events_backward({-1, -1}, 50, true)
    assert length(resp.events) == 50
  end

  @tag :event_journal
  @tag :event_journal_delete_stream
  test "should soft delete stream from event journal" do
    stream = "journal_test-#{UUID.uuid4()}"
    number_of_events = 20

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, number_of_events} == Journal.append_to_stream(stream, events, -1)

    assert {:ok, %{commit_position: cp, prepare_position: pp}} =
             Journal.delete_stream(stream, number_of_events)

    assert cp > 0 and pp > 0

    assert {:error, :no_stream} == Journal.read_event(stream, number_of_events)

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:error, :wrong_expected_version} == Journal.append_to_stream(stream, events, 0)

    assert {:ok, 2 * number_of_events + 1} ==
             Journal.append_to_stream(stream, events, number_of_events)
  end

  @tag :event_journal
  @tag :event_journal_delete_stream
  test "should hard delete stream from event journal" do
    stream = "journal_test-#{UUID.uuid4()}"
    number_of_events = 20

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, number_of_events} == Journal.append_to_stream(stream, events, -1)

    assert {:ok, %{commit_position: cp, prepare_position: pp}} =
             Journal.delete_stream(stream, number_of_events, true)

    assert cp > 0 and pp > 0

    assert {:error, :stream_deleted} == Journal.read_event(stream, number_of_events)

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:error, :stream_deleted} == Journal.append_to_stream(stream, events, 0)
    assert {:error, :stream_deleted} == Journal.append_to_stream(stream, events, number_of_events)
  end

  @tag :event_journal
  @tag :event_journal_stream_metadata
  test "should write and read stream metadata to and from event journal" do
    stream = "journal_test_write_metadata"
    number_of_events = 20

    metadata = %{
      # 2 seconds
      "$maxAge" => 2
    }

    assert {:ok, 0} == Journal.set_stream_metadata(stream, metadata, -1)

    events =
      Enum.map(
        0..number_of_events,
        &Messages.EventData.new(Extreme.Tools.gen_uuid(), UserCreated, %UserCreated{
          first_name: "Test #{&1}",
          last_name: "Lastname #{&1}"
        })
      )

    assert {:ok, number_of_events} == Journal.append_to_stream(stream, events, -1)

    Process.sleep(3000)

    assert 0 ==
             Journal.read_stream_events_forward(stream, 0, 50)
             |> elem(1)
             |> Map.get(:events)
             |> length()

    assert {:ok, %{metadata: _metadata, meta_version: 0}} = Journal.get_stream_metadata(stream)

    # assert {:ok, 1} == Journal.set_stream_metadata(stream, %{}, 0) # this requires scavage to be run in eventstore before executing below lines

    assert {:ok, 2 * number_of_events + 1} ==
             Journal.append_to_stream(stream, events, number_of_events)

    assert number_of_events + 1 ==
             Journal.read_stream_events_forward(stream, 0, 50)
             |> elem(1)
             |> Map.get(:events)
             |> length()
  end
end
