defmodule Helios.Aggregate.SnapshotOffer do
  alias Helios.EventJournal.Messages.PersistedEvent

  @moduledoc """
  Represents saved snapshot. Offered once aggregate started for the first time
  """

  defstruct [:stream, :event_number, :payload, :snapshot_number, :snapshot_date]

  @type t :: %__MODULE__{
          stream: String.t(),
          event_number: integer,
          payload: any,
          snapshot_number: integer,
          snapshot_date: DateTime.t() | nil
        }

  @doc false
  def from_journal(%PersistedEvent{metadata: metadata} = event) do
    struct!(__MODULE__,
      payload: event.data,
      stream: event.stream_id,
      snapshot_number: event.event_number,
      event_number: metadata.from_event_number,
      snapshot_date: event.created
    )
  end
end
