defmodule Helios.Aggregate.SnapshotOffer do
  @moduledoc """
  Represents saved snapshot. Offered once aggregate started for the first time
  """

  defstruct [:stream, :event_number, :data, :sequence_no, :snapshot_date]

  @type t :: %__MODULE__{
    stream: String.t(),
    event_number: integer,
    data: binary,
    sequence_no: integer,
    snapshot_date: NaiveDateTime.t()
  }
end
