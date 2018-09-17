defmodule Helios.EventJournal do
  @moduledoc """
  EventJournal

  ## Config Example
    use Mix.Config

    config :my_app, MyApp.EventJournal,
      adapter: Helios.EventJournal.Adapter.Eventstore
      adapter_config: [
        db_type: :node,
        host: "localhost",
        port: 1113,
        username: "admin",
        password: "changeit",
        reconnect_delay: 2_000,
        connection_name: "my_connection_name",
        max_attempts: :infinity
      ]

  ## Example Code
    defmodule MyApp.EventJournal do
      use Helios.EventJournal.EventJournal, ot_app: :my_app
    end

    defmodule MyApp.Events.UserCreated do
      defstruct [:id, :email]
    end

    alias MyApp.EventJournal, as: Journal
    alias  MyApp.Events.UserCreated
    alias Helios.EventJournal.Messages.EventData

    stream = "users-1234"
    events = [EventData.new(Extreme.Tools.gen_uuid(), MyApp.Events.UserCreated, %UserCreated{id: 1234, email: "example@example.com"})]
    metadata = %{}
    expected_version = -2

    {:ok, last_event_number} = Journal.append_to_stream(stream, events, expected_version)

  """
  alias Helios.EventJournal.Messages

  defmacro __using__(otp_app: otp_app) do
    quote do
      @behaviour Helios.EventJournal

      {otp_app, adapter, behaviours, config} =
        Helios.EventJournal.compile_config(__MODULE__, unquote(otp_app))

      @otp_app otp_app
      @adapter adapter
      @config config

      def config do
        opts = Application.get_env(@otp_app, __MODULE__, [])
        config = opts[:adapter_config]
        config
      end

      def __adapter__ do
        @adapter
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        __adapter__().start_link(__MODULE__, @config, opts)
      end

      def stop(timeout \\ 5000) do
        Supervisor.stop(__MODULE__, :normal, timeout)
      end

      @Impl
      def append_to_stream(stream, events, expexted_version \\ -1) do
        __adapter__().append_to_stream(__MODULE__, stream, events, expexted_version)
      end

      @Impl
      def read_event(stream, event_number, resolve_links \\ false) do
        __adapter__().read_event(__MODULE__, stream, event_number, resolve_links)
      end

      @Impl
      def read_stream_events_forward(stream, event_number, max_events, resolve_links \\ false) do
        __adapter__().read_stream_events_forward(
          __MODULE__,
          stream,
          event_number,
          max_events,
          resolve_links
        )
      end

      @Impl
      def read_stream_events_backward(stream, event_number, max_events, resolve_links \\ false) do
        __adapter__().read_stream_events_backward(
          __MODULE__,
          stream,
          event_number,
          max_events,
          resolve_links
        )
      end

      @Impl
      def read_all_events_forward(position, max_events, resolve_links \\ false) do
        __adapter__().read_all_events_forward(
          __MODULE__,
          position,
          max_events,
          resolve_links
        )
      end

      @Impl
      def read_all_events_backward(position, max_events, resolve_links \\ false) do
        __adapter__().read_all_events_backward(
          __MODULE__,
          position,
          max_events,
          resolve_links
        )
      end

      @Impl
      def delete_stream(stream, expected_version, hard_delete? \\ false) do
        __adapter__().delete_stream(__MODULE__, stream, expected_version, hard_delete?)
      end

      def get_stream_metadata(stream) do
        __adapter__().get_stream_metadata(__MODULE__, stream)
      end

      def set_stream_metadata(stream, expected_version, metadata) do
        __adapter__().set_stream_metadata(__MODULE__, stream, expected_version, metadata)
      end
    end
  end

  @type stream_name :: String.t()
  @type event_number :: integer

  @type append_error ::
          :wrong_expected_version
          | :stream_deleted
          | :access_denied

  @doc "Append events to stream if given expected version matches to last written event in journals database"
  @callback append_to_stream(
              stream :: stream_name(),
              events :: list(struct),
              expexted_version :: event_number()
            ) ::
              {:ok, event_number}
              | {:error, append_error}

  @doc "Reads single event from stream"
  @callback read_event(
              stream :: stream_name(),
              event_number :: event_number(),
              resolve_links :: boolean
            ) ::
              {:ok, Messages.PersistedEvent.t()}
              | {:error, Messages.PersistedEvent.read_error()}

  @doc "Reads forward `max_events` events from journal from given position"
  @callback read_stream_events_forward(
              stream :: stream_name(),
              event_number :: event_number(),
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadStreamEventsResponse.t())}
              | {:error, Messages.ReadStreamEventsResponse.read_error()}

  @doc "Reads `max_events` events from journal from given position backward until max_events or begining of stream is reached"
  @callback read_stream_events_backward(
              stream :: stream_name(),
              event_number :: event_number(),
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadStreamEventsResponse.t())}
              | {:error, Messages.ReadStreamEventsResponse.read_error()}

  @callback read_all_events_forward(
              position :: {integer, integer},
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadAllEventsResponse.t())}
              | {:error, Messages.ReadAllEventsResponse.read_error()}

  @callback read_all_events_backward(
              position :: {integer, integer},
              max_events :: integer,
              resolve_links :: boolean
            ) ::
              {:ok, list(Messages.ReadAllEventsResponse.t())}
              | {:error, Messages.ReadAllEventsResponse.read_error()}

  @callback delete_stream(
              stream :: String.t(),
              expected_version :: integer,
              hard_delete? :: boolean
            ) ::
              {:ok, Messages.Position.t()}
              | {:error, :wrong_expected_version}
              | {:error, :stream_deleted}
              | {:error, :access_denied}
              | {:error, any}

  @callback get_stream_metadata(stream :: String.t()) ::
              {:ok, Messages.StreamMetadataResponse.t()}
              | {:error, :stream_deleted}
              | {:error, :no_stream}
              | {:error, :not_found}
              | {:error, any}

  @callback set_stream_metadata(
              stream :: String.t(),
              expected_version :: event_number,
              metadata :: map
            ) ::
              {:ok, event_number}
              | {:error, :stream_deleted}
              | {:error, :no_stream}
              | {:error, :not_found}
              | {:error, :access_denied}
              | {:ettot, any}

  def compile_config(repo, otp_app) do
    opts = Application.get_env(otp_app, repo, [])
    adapter = opts[:adapter]
    config = opts[:adapter_config]

    unless adapter do
      raise ArgumentError,
            "missing :adapter config option on `use Helios.EventJournal`"
    end

    unless Code.ensure_loaded?(adapter) do
      raise ArgumentError,
            "adapter #{inspect(adapter)} was not compiled, " <>
              "ensure it is correct and it is included as a project dependency"
    end

    behaviours =
      for {:behaviour, behaviours} <- adapter.__info__(:attributes),
          behaviour <- behaviours,
          do: behaviour

    unless Helios.EventJournal.Adapter in behaviours do
      raise ArgumentError,
            "expected :adapter option given to Ecto.Repo to list Ecto.Adapter as a behaviour"
    end

    {otp_app, adapter, behaviours, config}
  end
end
