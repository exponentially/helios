defmodule Helios.EventJournal.Adapter do
  @moduledoc """
  Defines behaviour for EventJournal adapter.
  """
  alias Helios.EventJournal.Messages

  @type stream_name :: String.t()
  @type event_number :: integer

  @type append_error ::
          :wrong_expected_version
          | :stream_deleted
          | :access_denied

  @callback start_link(module :: module(), config :: keyword(), opts :: keyword()) ::
              :ignore | {:error, any()} | {:ok, pid()}

  @doc "Append events to stream if given expected version matches to last written event in journals database"
  @callback append_to_stream(
              server :: module,
              stream :: stream_name(),
              events :: list(Messages.EventData.t()),
              expexted_version :: event_number()
            ) ::
              {:ok, event_number}
              | {:error, append_error}

  @doc "Reads single event from stream"
  @callback read_event(
              server :: module,
              stream :: stream_name(),
              event_number :: event_number(),
              resolve_links :: boolean
            ) ::
              {:ok, Messages.PersistedEvent.t()}
              | {:error, Messages.PersistedEvent.read_error()}

  @doc "Reads forward `max_events` events from journal from given position"
  @callback read_stream_events_forward(
              server :: module,
              stream :: stream_name(),
              event_number :: event_number(),
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadStreamEventsResponse.t())}
              | {:error, Messages.ReadStreamEventsResponse.read_error()}

  @doc "Reads `max_events` events from journal from given position backward until max_events or begining of stream is reached"
  @callback read_stream_events_backward(
              server :: module,
              stream :: stream_name(),
              event_number :: event_number(),
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadStreamEventsResponse.t())}
              | {:error, Messages.ReadStreamEventsResponse.read_error()}

  @callback read_all_events_forward(
              server :: module,
              position :: {integer, integer},
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadAllEventsResponse.t())}
              | {:error, Messages.ReadAllEventsResponse.read_error()}

  @callback read_all_events_backward(
              server :: module,
              position :: {integer, integer},
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadAllEventsResponse.t())}
              | {:error, Messages.ReadAllEventsResponse.read_error()}

  @callback delete_stream(
              server :: module,
              stream :: String.t(),
              expected_version :: integer,
              hard_delete :: boolean
            ) ::
              {:ok, list(Messages.Position.t())}
              | {:error, Messages.ReadAllEventsResponse.read_error()}

  @callback set_stream_metadata(
              server :: module,
              stream :: stream_name(),
              metadata :: map,
              expexted_version :: event_number()
            ) ::
              {:ok, event_number}
              | {:error, append_error}

  @callback get_stream_metadata(server :: module, stream :: stream_name()) ::
              {:ok, event_number} | {:error, append_error}
end
