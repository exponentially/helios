defmodule Helios.EventJournal.Messages do
  @moduledoc false
  defmodule ReadStreamEventsResponse do
    @moduledoc """
    Represents response got from event journal
    """
    @type read_error :: :stream_not_found | :stream_deleted | String.t()
    @type t :: %__MODULE__{
            events: list(Helios.EventJournal.Messages.PersistedEvent.t()),
            next_event_number: integer,
            last_event_number: integer,
            is_end_of_stream: boolean,
            last_commit_position: integer
          }
    defstruct events: [],
              next_event_number: nil,
              last_event_number: nil,
              is_end_of_stream: false,
              last_commit_position: nil
  end

  defmodule Position do
    @moduledoc """
    Represents position in event journal
    """
    @type t :: %__MODULE__{
            commit_position: integer,
            prepare_position: integer
          }

    defstruct commit_position: 0, prepare_position: 0

    def journal_start() do
      struct(__MODULE__, commit_position: 0, prepare_position: 0)
    end

    def journal_end() do
      struct(__MODULE__, commit_position: -1, prepare_position: -1)
    end

    def new(commit_position, prepare_position) do
      struct(__MODULE__, commit_position: commit_position, prepare_position: prepare_position)
    end
  end

  defmodule EventData do
    @moduledoc """
    Holds metadata and event data of emitted event.

    Use this structure when you want to store event in event journal.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            type: String.t(),
            data: struct | map,
            metadata: nil | map
          }
    defstruct [:id, :type, :data, :metadata]

    @doc """
    Creates new `EventData`
    """
    def new(id, type, data, metadata \\ %{})

    def new(id, type, data, metadata) when is_atom(type),
      do: new(id, Atom.to_string(type), data, metadata)

    def new(id, type, data, metadata) when is_binary(type) do
      struct(
        __MODULE__,
        id: id,
        type: type,
        data: data,
        metadata: metadata || %{}
      )
    end
  end

  defmodule PersistedEvent do
    @moduledoc """
    Represents persisted event.
    """
    @type read_error :: :not_found | :no_stream | :stream_deleted | String.t()
    @type t :: %__MODULE__{
            stream_id: String.t(),
            event_number: integer,
            event_id: String.t(),
            event_type: String.t(),
            data: nil | map | struct,
            metadata: nil | map,
            created: DateTime.t(),
            position: nil | Position.t()
          }

    defstruct stream_id: nil,
              event_number: nil,
              event_id: nil,
              event_type: 1,
              data: nil,
              metadata: %{},
              created: nil,
              position: nil
  end

  defmodule ReadAllEventsResponse do
    @moduledoc """
    Holds read result when all events are read from event journal.
    """
    @type read_error :: String.t()
    @type t :: %__MODULE__{
            commit_position: integer,
            prepare_position: integer,
            events: list(Helios.EventJournal.Messages.PersistedEvent.t()),
            next_commit_position: integer,
            next_prepare_position: integer
          }

    defstruct commit_position: nil,
              prepare_position: nil,
              events: [],
              next_commit_position: nil,
              next_prepare_position: nil
  end

  defmodule StreamMetadataResponse do
    @moduledoc """
    Holds stream metadata.
    """
    @type t :: %__MODULE__{
            stream: String.t(),
            is_deleted: boolean,
            meta_version: integer,
            metadata: map
          }

    defstruct stream: nil, is_deleted: false, meta_version: -1, metadata: %{}

    @spec new(String.t(), boolean, integer, map) :: __MODULE__.t()
    def new(stream, is_deleted, meta_version, metadata) do
      %__MODULE__{
        stream: stream,
        is_deleted: is_deleted,
        meta_version: meta_version,
        metadata: metadata || %{}
      }
    end
  end
end
