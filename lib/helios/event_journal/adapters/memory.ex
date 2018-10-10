defmodule Helios.EventJournal.Adapter.Memory do
  @moduledoc """
  Simple memory event journal adapter.

  Events are kept in ETS table
  """
  use GenServer
  require Logger

  # alias Helios.EventJournal.Messages.EventData
  alias Helios.EventJournal.Messages.ReadStreamEventsResponse
  alias Helios.EventJournal.Messages.ReadAllEventsResponse
  alias Helios.EventJournal.Messages.PersistedEvent
  alias Helios.EventJournal.Messages.Position
  alias Helios.EventJournal.Messages.StreamMetadataResponse

  @behaviour Helios.EventJournal.Adapter

  @max_event_no 9_223_372_036_854_775_807
  @streams "Streams"
  @events "Events"
  @all "$all"

  @impl true
  def start_link(module, config, opts \\ []) do
    opts = Keyword.put(opts, :name, module)
    GenServer.start_link(__MODULE__, {module, config}, opts)
  end

  @impl Helios.EventJournal.Adapter
  def append_to_stream(server, stream, events, expexted_version) do
    GenServer.call(server, {:append_to_stream, stream, events, expexted_version})
  end

  @impl Helios.EventJournal.Adapter
  def read_event(server, stream, event_number, _resolve_links \\ false) do
    # fun =
    # :ets.fun2ms(fn {idx, stream_id, sequence_number, event_id, event_type, data, metadata,
    #                 created}
    #                when stream_id == stream and sequence_number == event_number ->
    #   {idx, stream_id, sequence_number, event_id, event_type, data, metadata, created}
    # end)
    meta = get_stream_metadata(server, stream)

    fun = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
       [{:andalso, {:==, :"$2", {:const, stream}}, {:==, :"$3", {:const, event_number}}}],
       [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]}
    ]

    res = :ets.select(events(server), fun)

    case {res, meta} do
      {[head | _], _} ->
        to_persisted(head)

      {[], {:ok, %{is_deleted: true}}} ->
        {:error, :stream_deleted}

      {[], {:ok, %{is_deleted: false}}} ->
        {:error, :no_stream}

      {[], {:error, error}} ->
        {:error, error}
    end
  end

  @impl Helios.EventJournal.Adapter
  def read_stream_events_forward(
        server,
        stream,
        event_number,
        max_events,
        _resolve_links \\ false
      ) do
    # TODO: read stream metadata and check if $maxAge, or similar metadata is set there
    # so we can skeep events that should be scavaged later

    # fun =
    #   :ets.fun2ms(fn {idx, stream_id, sequence_number, event_id, event_type, data, metadata,
    #                   created}
    #                  when stream_id == stream and sequence_number >= event_number and sequence_number <= max_events ->
    #     {idx, stream_id, sequence_number, event_id, event_type, data, metadata, created}
    #   end)
    event_number = if event_number < 0, do: 0, else: event_number
    last_event_number = event_number + max_events

    fun = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
       [
         {:andalso,
          {:andalso, {:==, :"$2", {:const, stream}}, {:>=, :"$3", {:const, event_number}}},
          {:<, :"$3", {:const, last_event_number}}}
       ], [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]}
    ]

    persisted_events =
      server
      |> events()
      |> :ets.select(fun)
      |> Enum.map(& elem(to_persisted(&1), 1))

    last_event_number = get_stream_event_number(server, stream)
    last_commit_position = get_idx(server)

    case List.last(persisted_events) do
      nil ->
        {:ok,
         %ReadStreamEventsResponse{
           events: persisted_events,
           next_event_number: -1,
           last_event_number: last_event_number,
           is_end_of_stream: true,
           last_commit_position: last_commit_position
         }}

      event ->
        {:ok,
         %ReadStreamEventsResponse{
           events: persisted_events,
           next_event_number:
             if(
               last_event_number > event.event_number,
               do: event.event_number + 1,
               else: event.event_number
             ),
           last_event_number: last_event_number,
           is_end_of_stream: true,
           last_commit_position: last_commit_position
         }}
    end
  end

  @impl Helios.EventJournal.Adapter
  def read_stream_events_backward(
        server,
        stream,
        event_number,
        max_events,
        _resolve_links \\ false
      ) do
    # fun =
    # :ets.fun2ms(fn {idx, stream_id, sequence_number, event_id, event_type, data, metadata,
    #                 created}
    #                when stream_id == stream and sequence_number <= event_number and sequence_number >= max_events ->
    #   {idx, stream_id, sequence_number, event_id, event_type, data, metadata, created}
    # end)
    last_event_number = event_number - max_events

    fun = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
       [
         {:andalso,
          {:andalso, {:==, :"$2", {:const, stream}}, {:"=<", :"$3", {:const, event_number}}},
          {:>, :"$3", {:const, last_event_number}}}
       ], [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]}
    ]

    persisted_events =
      server
      |> events()
      |> :ets.select(fun)
      |> Enum.map(& elem(to_persisted(&1), 1))
      |> Enum.reverse()

    last_event_number = get_stream_event_number(server, stream)
    last_commit_position = get_idx(server)

    case List.last(persisted_events) do
      nil ->
        {:ok,
         %ReadStreamEventsResponse{
           events: persisted_events,
           next_event_number: -1,
           last_event_number: last_event_number,
           is_end_of_stream: TRUE,
           last_commit_position: last_commit_position
         }}

      event ->
        {:ok,
         %ReadStreamEventsResponse{
           events: persisted_events,
           next_event_number:
             if(
               last_event_number > event.event_number,
               do: event.event_number + 1,
               else: event.event_number
             ),
           last_event_number: last_event_number,
           is_end_of_stream: true,
           last_commit_position: last_commit_position
         }}
    end
  end

  @impl Helios.EventJournal.Adapter
  def read_all_events_forward(server, {commit_position, _}, max_events, _resolve_links \\ false) do
    last_commit_position = get_idx(server)

    commit_position =
      if commit_position <= -1 do
        last_commit_position + 1
      else
        commit_position
      end

    from_position = commit_position
    until_position = commit_position + max_events

    fun = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
       [
         {:andalso, {:andalso, {:>=, :"$1", {:const, from_position}}},
          {:<, :"$1", {:const, until_position}}}
       ], [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]}
    ]

    persisted_events =
      server
      |> events()
      |> :ets.select(fun)
      |> Enum.map(& elem(to_persisted(&1), 1))

    case List.last(persisted_events) do
      nil ->
        {:ok,
         %ReadAllEventsResponse{
           commit_position: -1,
           prepare_position: -1,
           events: [],
           next_commit_position: -1,
           next_prepare_position: -1
         }}

      event ->
        pos = event.position.commit_position

        next_pos =
          if(
            last_commit_position > pos,
            do: pos + 1,
            else: pos
          )

        {:ok,
         %ReadAllEventsResponse{
           commit_position: pos,
           prepare_position: pos,
           events: persisted_events,
           next_commit_position: next_pos,
           next_prepare_position: next_pos
         }}
    end
  end

  @impl Helios.EventJournal.Adapter
  def read_all_events_backward(server, {commit_position, _}, max_events, _resolve_links \\ false) do
    last_commit_position = get_idx(server)

    commit_position =
      if commit_position < 0 or commit_position >= last_commit_position do
        last_commit_position
      else
        commit_position
      end

    from_position = commit_position - max_events
    until_position = commit_position

    fun = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
       [
         {:andalso, {:andalso, {:>=, :"$1", {:const, from_position}}},
          {:<, :"$1", {:const, until_position}}}
       ], [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]}
    ]

    persisted_events =
      server
      |> events()
      |> :ets.select(fun)
      |> Enum.map(& elem(to_persisted(&1), 1))

    case List.last(persisted_events) do
      nil ->
        {:ok,
         %ReadAllEventsResponse{
           commit_position: -1,
           prepare_position: -1,
           events: [],
           next_commit_position: -1,
           next_prepare_position: -1
         }}

      event ->
        pos = event.position.commit_position

        next_pos =
          if(
            last_commit_position > pos,
            do: pos + 1,
            else: pos
          )

        {:ok,
         %ReadAllEventsResponse{
           commit_position: pos,
           prepare_position: pos,
           events: persisted_events,
           next_commit_position: next_pos,
           next_prepare_position: next_pos
         }}
    end
  end

  @impl Helios.EventJournal.Adapter
  def delete_stream(server, stream, expected_version, hard_delete?) do
    GenServer.call(server, {:delete_stream, stream, expected_version, hard_delete?})
  end

  @impl Helios.EventJournal.Adapter
  def set_stream_metadata(server, stream, metadata, expexted_version) do
    GenServer.call(server, {:set_stream_metadata, stream, metadata, expexted_version})
  end

  @impl Helios.EventJournal.Adapter
  def get_stream_metadata(server, stream) do
    case :ets.lookup(streams(server), stream) do
      [{stream, sequence_no, meta} | _] ->
        resp = %StreamMetadataResponse{
          stream: stream,
          is_deleted: sequence_no == @max_event_no,
          meta_version: 0,
          metadata: meta
        }

        {:ok, resp}

      [] ->
        {:error, :no_stream}
    end
  end

  # SERVER

  @impl GenServer
  def init({module, _}) do
    :ets.new(streams(module), [:set, :protected, :named_table])
    :ets.new(events(module), [:ordered_set, :protected, :named_table])

    {:ok, %{module: module}}
  end

  @impl GenServer
  def handle_call({:append_to_stream, stream, events, expected_ver}, _, s) do
    do_append_to_stream(
      stream,
      events,
      expected_ver,
      get_idx(s.module),
      get_stream_event_number(s.module, stream),
      s
    )
  end

  def handle_call({:delete_stream, stream, expected_version, hard_delete?}, _, s) do
    # :ets.fun2ms(fn
    #   {idx, stream_id, sequence_number, event_id, event_type, data, metadata, created} when stream_id == stream ->
    #   {idx}
    # end)

    last_event_number = get_stream_event_number(s.module, stream)

    if expected_version == last_event_number do
      fun = [
        {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
         [{:==, :"$2", {:const, stream}}], [{{:"$1"}}]}
      ]

      persisted =
        s.module
        |> events()
        |> :ets.select(fun)

      persisted
      |> Enum.each(fn {idx} ->
        :ets.delete(events(s.module), idx)
      end)

      case {List.last(persisted), last_event_number} do
        {nil, num} when num > -1 and num < @max_event_no ->
          {:reply, {:ok, :no_stream}, s}

        {nil, num} when num == @max_event_no ->
          {:reply, {:error, :stream_deleted}, s}

        {idx, _num} ->
          if hard_delete? do
            {:ok, sm} = get_stream_metadata(s.module, stream)
            :ets.insert(streams(s.module), {stream, @max_event_no, sm.metadata})
          end

          pos = %Position{commit_position: idx, prepare_position: idx}
          {:reply, {:ok, pos}, s}
      end
    else
      {:reply, {:error, :wrong_expected_version}, s}
    end
  end

  def handle_call({:set_stream_metadata, stream, metadata, expexted_version}, _from, s) do
    event_number = get_stream_event_number(s.module, stream)
    :ets.insert(streams(s.module), {stream, event_number, metadata})
    {:reply, {:ok, expexted_version + 1}, s}
  end

  defp do_append_to_stream(
         _stream,
         _events,
         _expexted_version,
         _last_event_number,
         stream_event_number,
         s
       )
       when stream_event_number == @max_event_no do
    {:reply, {:error, :stream_deleted}, s}
  end

  defp do_append_to_stream(
         _stream,
         _events,
         expexted_version,
         _last_event_number,
         stream_event_number,
         s
       )
       when expexted_version != stream_event_number do
    {:reply, {:error, :wrong_expected_version}, s}
  end

  defp do_append_to_stream(
         stream,
         events,
         expexted_version,
         last_event_number,
         stream_event_number,
         s
       )
       when expexted_version < 0 or expexted_version == stream_event_number do
    {last_event_number, stream_event_number} =
      Enum.reduce(events, {last_event_number, stream_event_number}, fn event,
                                                                       {idx, event_number} ->
        idx = idx + 1
        stream_id = stream
        event_number = event_number + 1
        event_id = event.id
        event_type = event.type
        data = event.data
        metadata = event.metadata || %{}
        created = DateTime.utc_now()

        true =
          :ets.insert(
            events(s.module),
            {idx, stream_id, event_number, event_id, event_type, data, metadata, created}
          )

        {idx, event_number}
      end)

    :ets.insert(streams(s.module), {@all, last_event_number, %{}})

    case get_stream_metadata(s.module, stream) do
      {:ok, r} ->
        :ets.insert(streams(s.module), {stream, stream_event_number, r.metadata})

      _ ->
        :ets.insert(streams(s.module), {stream, stream_event_number, %{}})
    end

    {:reply, {:ok, stream_event_number}, s}
  end

  defp streams(module) do
    Module.concat(module, @streams)
  end

  defp events(module) do
    Module.concat(module, @events)
  end

  defp get_idx(module) do
    case :ets.lookup(streams(module), @all) do
      [] -> -1
      [{@all, event_number, _} | _] -> event_number
    end
  end

  defp get_stream_event_number(module, stream) do
    case :ets.lookup(streams(module), stream) do
      [] -> -1
      [{^stream, event_number, _} | _] -> event_number
    end
  end

  defp to_persisted({idx, stream_id, event_number, event_id, event_type, data, metadata, created}) do
    response = %PersistedEvent{
      stream_id: stream_id,
      event_number: event_number,
      event_id: event_id,
      event_type: event_type,
      data: data,
      metadata: metadata,
      position: %Position{
        commit_position: idx,
        prepare_position: idx
      },
      created: created
    }

    {:ok, response}
  end
end
