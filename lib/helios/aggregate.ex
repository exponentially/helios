defmodule Helios.Aggregate do
  @moduledoc """
  Aggregate behaviour.
  """

  alias Helios.Pipeline.Context

  @type aggregate_id :: String.t()

  @type t :: struct()

  @doc """
  Handles execution of the command.
  """
  @callback handle(ctx :: Context.t(), params :: Context.params()) :: Context.t()

  @doc """
  Applies single event to aggregate when replied or after `handle_exec/3` is executed.

  Must return `{:ok, state}` if event is aplied or raise an error if failed.
  Note that events should not be validated here, they must be respected since handle_execute/3
  generated event and already validate it. Also, error has to bi risen in for some odd reason event cannot
  be applied to aggregate.
  """
  @callback apply_event(event :: any, aggregate :: __MODULE__.t()) :: __MODULE__.t() | no_return

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      import Helios.Aggregate
      import Helios.Pipeline.Context

      use Helios.Pipeline, opts

      @doc """
      Creates new state. Called once during aggregate recovery or creation.

      Override this function if your state struct
      is not defined in module that implements `Helios.Aggregate` behaviour,
      or you need to initialize some values before recovery starts.
      """
      def new() do
        struct(__MODULE__, [])
      end

      defoverridable new: 0
    end
  end

  @doc false
  def plug_init_mode() do
    Application.get_env(:helios_aggregate, :plug_init_mode, :compile)
  end
end
