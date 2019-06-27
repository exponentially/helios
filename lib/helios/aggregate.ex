defmodule Helios.Aggregate do
  @moduledoc """
  Aggregate behaviour.

  Once implemented add command mapping to router `Helios.Router`.
  """

  alias Helios.Context

  @typedoc """
  The unique aggregate id.
  """
  @type aggregate_id :: String.t()

  @type aggregate :: struct()

  @type from :: {pid(), tag :: term()}

  @type init_args :: [otp_app: atom, id: aggregate_id]

  @doc """
  Returns unique identifier for stream to which events will be persisted.

  This persistance id will be used while persisting events emitted by aggregate into
  its own stream of the events.
  """
  @callback persistance_id(id :: term) :: String.t()

  @doc """
  Handles execution of the command once command is handed from router to
  `Helios.Aggregate.Server`.
  """
  @callback handle(ctx :: Context.t(), params :: Context.params()) :: Context.t()

  @doc """
  Constructs new instance of aggregate struct. Override to set defaults or if your
  struct is defined in different module.
  """
  @callback init(args :: init_args) :: aggregate

  @doc """
  Applies single event to aggregate when replied or after `handle_exec/3` is executed.

  Must return `{:ok, state}` if event is aplied or raise an error if failed.
  Note that events should not be validated here, they must be respected since handle_execute/3
  generated event and already validate it. Also, error has to bi risen in for some odd reason event cannot
  be applied to aggregate.
  """
  @callback apply_event(event :: any, aggregate) :: aggregate | no_return

  @doc """
  Optional cllback, when implemented it should treansform offered snapshot into
  aggregate model.

  Return `{:ok, aggregate}` if snapshot is applied to aggregate, or
  `{:ignored, aggregate}` if you want ignore snapshot and apply all events from
  beginning of the aggregate stream
  """
  @callback from_snapshot(snapshot_offer :: SnapshotOffer.t(), aggregate) ::
              {:ok, aggregate}
              | {:skip, aggregate}

  @doc """
  Optional callback, when implmented it should return snapshot of given aggregate.

  When snapshot is stored it should record among aggregate state, sequence number
  (or last_event_number) at which snapshot was taken.
  """
  @callback to_snapshot(aggregate) :: any

  @optional_callbacks [
    # Aggregate
    from_snapshot: 2,
    to_snapshot: 1
  ]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      import Helios.Aggregate
      import Helios.Context

      use Helios.Pipeline, opts
    end
  end

  def state(%Context{assigns: %{aggregate: aggregate}} = _), do: aggregate

  def state(_ctx), do: nil
end
