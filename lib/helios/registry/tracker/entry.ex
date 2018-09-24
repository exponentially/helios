defmodule Helios.Registry.Tracker.Entry do
  @moduledoc false
  alias Helios.Registry.Tracker.IntervalTreeClock, as: ITC

  @fields [name: nil, pid: nil, ref: nil, meta: %{}, clock: nil]

  require Record
  Record.defrecord(:entry, @fields)

  @type entry ::
          record(
            :entry,
            name: term,
            pid: pid,
            ref: reference,
            meta: nil | map,
            clock: nil | ITC.t()
          )

  def index(field) when is_atom(field) do
    Record.__access__(:entry, @fields, field, Helios.Registry.Entry)
  end
end
