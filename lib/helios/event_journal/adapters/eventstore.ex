if Code.ensure_compiled?(Extreme) do
  defmodule Helios.EventJournal.Adapter.Eventstore do
    @moduledoc """
    EventJournal adapter for Eventstore database.
    """
    @behaviour Helios.EventJournal.Adapter
    alias Helios.EventJournal.Messages
    alias Extreme.Msg, as: ExMsg

    @spec start_link(module(), keyword(), keyword()) :: :ignore | {:error, any()} | {:ok, pid()}
    def start_link(module, config, opts \\ []) do
      opts = Keyword.put(opts, :name, module)
      Extreme.start_link(config, opts)
    end

    @doc """
    Appends events to stream from given expected version. If expected version do not match
    the one that matches last event number in evenent store it will respond with {:error, :wrong_expected_version}
    """
    def append_to_stream(server, stream, events, expexted_version \\ -2) do
      request = append_to_stream_request(stream, events, expexted_version)

      case Extreme.execute(server, request) do
        {:ok, %{last_event_number: last_event_number}} ->
          {:ok, last_event_number}

        {:error, :WrongExpectedVersion, _} ->
          {:error, :wrong_expected_version}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    def read_event(server, stream, event_number, resolve_links \\ false) do
      request = read_event_request(stream, event_number, resolve_links)

      with {:ok, %ExMsg.ReadEventCompleted{event: event}} <- Extreme.execute(server, request),
           {:ok, persisted_event} <- to_persisted(event) do
        {:ok, persisted_event}
      else
        {:error, :NotFound, _} ->
          {:error, :not_found}

        {:error, :NoStream, _} ->
          {:error, :no_stream}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :Error, %ExMsg.ReadEventCompleted{error: error}} ->
          {:error, error}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    def read_stream_events_forward(
          server,
          stream,
          event_number,
          max_events,
          resolve_links \\ false
        ) do
      request = read_events_forward_request(stream, event_number, max_events, resolve_links)

      with {:ok, resp} <- Extreme.execute(server, request) do
        {:ok,
         %Messages.ReadStreamEventsResponse{
           events:
             Enum.map(resp.events, fn p ->
               {:ok, persisted_event} = to_persisted(p)
               persisted_event
             end),
           next_event_number: resp.next_event_number,
           last_event_number: resp.last_event_number,
           is_end_of_stream: resp.is_end_of_stream,
           last_commit_position: resp.last_commit_position
         }}
      else
        {:error, :NotModified, _} ->
          {:ok,
           %Messages.ReadStreamEventsResponse{
             is_end_of_stream: true,
             last_event_number: event_number,
             events: []
           }}

        {:error, :NoStream, _} ->
          {:error, :no_stream}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        {:error, :Error, %{error: error}} ->
          {:error, %{error: error}}

        other ->
          {:error, other}
      end
    end

    def read_stream_events_backward(
          server,
          stream,
          event_number,
          max_events,
          resolve_links \\ false
        ) do
      request = read_events_backward_request(stream, event_number, max_events, resolve_links)

      with {:ok, resp} <- Extreme.execute(server, request) do
        {:ok,
         %Messages.ReadStreamEventsResponse{
           events:
             Enum.map(resp.events, fn p ->
               {:ok, persisted_event} = to_persisted(p)
               persisted_event
             end),
           next_event_number: resp.next_event_number,
           last_event_number: resp.last_event_number,
           is_end_of_stream: resp.is_end_of_stream,
           last_commit_position: resp.last_commit_position
         }}
      else
        {:error, :NotModified, _} ->
          {:ok,
           %Messages.ReadStreamEventsResponse{
             is_end_of_stream: true,
             last_event_number: event_number,
             events: []
           }}

        {:error, :NoStream, _} ->
          {:error, :no_stream}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :Error, %ExMsg.ReadEventCompleted{error: error}} ->
          {:error, error}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    def read_all_events_forward(
          server,
          {commit_position, prepare_position} = pos,
          max_events,
          resolve_links
        ) do
      request = read_all_events_forward_request(pos, max_events, resolve_links)

      with {:ok, resp} <- Extreme.execute(server, request) do
        events =
          resp.events
          |> List.wrap()
          |> Enum.map(fn p ->
            {:ok, persisted_event} = to_persisted(p)
            persisted_event
          end)

        response = %Messages.ReadAllEventsResponse{
          events: events,
          commit_position: resp.commit_position,
          prepare_position: resp.prepare_position,
          next_commit_position: resp.next_commit_position,
          next_prepare_position: resp.next_prepare_position
        }

        {:ok, response}
      else
        {:error, :NotModified, _} ->
          resp = %Messages.ReadAllEventsResponse{
            events: [],
            commit_position: commit_position,
            prepare_position: prepare_position,
            next_commit_position: -1,
            next_prepare_position: -1
          }

          {:ok, resp}

        {:error, :NoStream, _} ->
          {:error, :no_stream}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :Error, %ExMsg.ReadAllEventsCompleted{error: error}} ->
          {:error, error}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    def read_all_events_backward(
          server,
          {commit_position, prepare_position} = pos,
          max_events,
          resolve_links
        ) do
      request = read_all_events_backward_request(pos, max_events, resolve_links)

      with {:ok, resp} <- Extreme.execute(server, request) do
        events =
          resp.events
          |> List.wrap()
          |> Enum.map(fn p ->
            {:ok, persisted_event} = to_persisted(p)
            persisted_event
          end)

        response = %Messages.ReadAllEventsResponse{
          events: events,
          commit_position: resp.commit_position,
          prepare_position: resp.prepare_position,
          next_commit_position: resp.next_commit_position,
          next_prepare_position: resp.next_prepare_position
        }

        {:ok, response}
      else
        {:error, :NotModified, _} ->
          resp = %Messages.ReadAllEventsResponse{
            events: [],
            commit_position: commit_position,
            prepare_position: prepare_position,
            next_commit_position: -1,
            next_prepare_position: -1
          }

          {:ok, resp}

        {:error, :NoStream, _} ->
          {:error, :no_stream}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :Error, %ExMsg.ReadAllEventsCompleted{error: error}} ->
          {:error, error}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    def delete_stream(server, stream, expected_version, hard_delete? \\ false) do
      request = delete_stream_request(stream, expected_version, hard_delete?)

      case Extreme.execute(server, request) do
        {:ok, %ExMsg.DeleteStreamCompleted{} = resp} ->
          pos =
            Messages.Position.new(
              resp.commit_position,
              resp.prepare_position
            )

          {:ok, pos}

        {:error, :WrongExpectedVersion, _} ->
          {:error, :wrong_expected_version}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        {:error, :Error, %{error: error}} ->
          {:error, error}

        other ->
          {:error, other}
      end
    end

    def get_stream_metadata(server, stream) do
      case read_event(server, "$$" <> stream, -1) do
        {:ok, event} ->
          {:ok,
           Messages.StreamMetadataResponse.new(
             stream,
             false,
             event.event_number,
             event.data || %{}
           )}

        {:error, error} when error in [:no_stream, :not_found] ->
          Messages.StreamMetadataResponse.new(stream, false, -1, %{})

        {:error, :stream_deleted} ->
          Messages.StreamMetadataResponse.new(stream, true, 9_223_372_036_854_775_807, %{})

        any ->
          any
      end
    end

    def set_stream_metadata(server, stream, metadata, expexted_version \\ -2) do
      message = set_strema_metadata_request(stream, metadata || %{}, expexted_version)

      case Extreme.execute(server, message) do
        {:ok, %{last_event_number: last_event_number}} ->
          {:ok, last_event_number}

        {:error, :WrongExpectedVersion, _} ->
          {:error, :wrong_expected_version}

        {:error, :StreamDeleted, _} ->
          {:error, :stream_deleted}

        {:error, :AccessDenied, _} ->
          {:error, :access_denied}

        other ->
          {:error, other}
      end
    end

    defp set_strema_metadata_request(stream, metadata, expected_version) when is_list(metadata) do
      set_strema_metadata_request(stream, Enum.into(metadata, %{}), expected_version)
    end

    defp set_strema_metadata_request(stream, metadata, expected_version) when is_map(metadata) do
      stream = "$$" <> stream

      events = [
        Messages.EventData.new(
          Extreme.Tools.gen_uuid(),
          "$metadata",
          metadata
        )
      ]

      append_to_stream_request(stream, events, expected_version)
    end

    defp append_to_stream_request(stream, events, expected_version) do
      proto_events =
        Enum.map(events, fn event_data ->
          metadata = if event_data.metadata != nil, do: Poison.encode!(event_data.metadata)

          ExMsg.NewEvent.new(
            event_id: event_data.id,
            event_type: event_data.type,
            data_content_type: 1,
            metadata_content_type: 1,
            data: Poison.encode!(event_data.data),
            metadata: metadata
          )
        end)

      ExMsg.WriteEvents.new(
        event_stream_id: stream,
        expected_version: expected_version,
        events: proto_events,
        require_master: false
      )
    end

    defp read_events_forward_request(stream, start_at, per_page, resolve_link_tos) do
      ExMsg.ReadStreamEvents.new(
        event_stream_id: stream,
        from_event_number: start_at,
        max_count: per_page,
        resolve_link_tos: resolve_link_tos,
        require_master: false
      )
    end

    defp read_events_backward_request(stream, start_at, per_page, resolve_link_tos) do
      ExMsg.ReadStreamEventsBackward.new(
        event_stream_id: stream,
        from_event_number: start_at,
        max_count: per_page,
        resolve_link_tos: resolve_link_tos,
        require_master: false
      )
    end

    defp read_all_events_forward_request(
           {commit_position, prepare_position},
           per_page,
           resolve_link_tos
         ) do
      {
        :read_all_events_forward,
        ExMsg.ReadAllEvents.new(
          commit_position: commit_position,
          prepare_position: prepare_position,
          max_count: per_page,
          resolve_link_tos: resolve_link_tos,
          require_master: false
        )
      }
    end

    defp read_all_events_backward_request(
           {commit_position, prepare_position},
           per_page,
           resolve_link_tos
         ) do
      {
        :read_all_events_backward,
        ExMsg.ReadAllEvents.new(
          commit_position: commit_position,
          prepare_position: prepare_position,
          max_count: per_page,
          resolve_link_tos: resolve_link_tos,
          require_master: false
        )
      }
    end

    defp delete_stream_request(stream, expected_version, hard_delete?) do
      ExMsg.DeleteStream.new(
        event_stream_id: stream,
        expected_version: expected_version,
        require_master: false,
        hard_delete: hard_delete?
      )
    end

    defp read_event_request(stream, event_number, resolve_link_tos?) do
      ExMsg.ReadEvent.new(
        event_stream_id: stream,
        event_number: event_number,
        resolve_link_tos: resolve_link_tos?,
        require_master: false
      )
    end

    defp to_persisted(%ExMsg.ResolvedEvent{} = msg) do
      event = Map.get(msg, :event) || Map.get(msg, :link)

      data =
        with 1 <- event.data_content_type,
             event_type <- String.to_atom(event.event_type) do
          opts =
            if Code.ensure_compiled?(event_type),
              do: [as: struct(event_type), keys: :atoms],
              else: []

          # todo: EventAdapters
          Poison.decode!(
            event.data || "{}",
            opts
          )
        else
          _ ->
            event.data
        end

      metadata =
        case {event.metadata_content_type, event.metadata} do
          {1, "{" <> _} -> Poison.decode!(event.metadata)
          _ -> event.metadata
        end

      response = %Messages.PersistedEvent{
        stream_id: event.event_stream_id,
        event_number: event.event_number,
        event_id: event.event_id,
        event_type: event.event_type,
        data: data,
        metadata: metadata,
        position: %Messages.Position{
          commit_position: msg.commit_position,
          prepare_position: msg.prepare_position
        },
        created:
          if(
            event.created_epoch != nil,
            do: DateTime.from_unix!(event.created_epoch, :millisecond)
          )
      }

      {:ok, response}
    end

    defp to_persisted(%ExMsg.ResolvedIndexedEvent{} = msg) do
      event = Map.get(msg, :event) || Map.get(msg, :link)

      data =
        case event.data_content_type do
          1 ->
            event_type = String.to_atom(event.event_type)

            opts =
              if Code.ensure_compiled?(event_type),
                do: [as: struct(event_type), keys: :atoms],
                else: []

            Poison.decode!(event.data, opts)

          _ ->
            event.data
        end

      metadata =
        case event.metadata_content_type do
          1 -> Poison.decode!(event.metadata, keys: :atoms)
          _ -> event.metadata
        end

      response = %Messages.PersistedEvent{
        stream_id: event.event_stream_id,
        event_number: event.event_number,
        event_id: event.event_id,
        event_type: event.event_type,
        data: data,
        metadata: metadata,
        created:
          if(
            event.created_epoch != nil,
            do: DateTime.from_unix!(event.created_epoch, :millisecond)
          )
      }

      {:ok, response}
    end
  end
end
