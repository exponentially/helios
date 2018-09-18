defmodule Helios.Endpoint do
  @type topic :: String.t()
  @type event :: String.t()
  @type msg :: map

  @doc """
  Starts endpoint supervision tree.
  """
  @callback start_link() :: Supervisor.on_start()

  @doc """
  Get configuration for given endpoint.
  """
  @callback config(key :: atom, default :: term) :: term

  @doc """
  Initializes endpoint configuration
  """
  @callback init(:supervisor, config :: Keyword.t()) :: {:ok, Keyword.t()}

  @doc """
  Subscribes the caller to the given topic.
  """
  @callback subscribe(topic :: __MODULE__.topic(), opts :: Keyword.t()) :: :ok | {:error, term}

  @doc """
  Unsubscribes the caller from the given topic.
  """
  @callback unsubscribe(topic :: __MODULE__.topic()) :: :ok | {:error, term}

  @doc """
  Broadcasts a `msg` as `event` in the given `topic`.
  """
  @callback broadcast(
              topic :: __MODULE__.topic(),
              event :: __MODULE__.event(),
              msg :: __MODULE__.msg()
            ) :: :ok | {:error, term}

  @doc """
  Broadcasts a `msg` as `event` in the given `topic`.

  Raises in case of failures.
  """
  @callback broadcast!(
              topic :: __MODULE__.topic(),
              event :: __MODULE__.event(),
              msg :: __MODULE__.msg()
            ) :: :ok | no_return

  @doc """
  Broadcasts a `msg` from the given `from` as `event` in the given `topic`.
  """
  @callback broadcast_from(
              from :: pid,
              topic :: __MODULE__.topic(),
              event :: __MODULE__.event(),
              msg :: __MODULE__.msg()
            ) :: :ok | {:error, term}

  @doc """
  Broadcasts a `msg` from the given `from` as `event` in the given `topic`.

  Raises in case of failures.
  """
  @callback broadcast_from!(
              from :: pid,
              topic :: __MODULE__.topic(),
              event :: __MODULE__.event(),
              msg :: __MODULE__.msg()
            ) :: :ok | no_return

  # Instrumentation

  @doc """
  Allows instrumenting operation defined by `function`.

  `runtime_metadata` may be omitted and defaults to `nil`.

  Read more about instrumentation in the "Instrumentation" section.
  """
  @macrocallback instrument(
                   instrument_event :: Macro.t(),
                   runtime_metadata :: Macro.t(),
                   funcion :: Macro.t()
                 ) :: Macro.t()

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Helios.Endpoint

      unquote(config(opts))
      # unquote(pubsub())
      unquote(plug())
      unquote(server())
    end
  end

  defp config(opts) do
    quote do
      @otp_app unquote(opts)[:otp_app] || raise("endpoint expects :otp_app to be given")
      var!(config) = Helios.Endpoint.Supervisor.config(@otp_app, __MODULE__)

      @doc """
      Callback invoked on endpoint initialization.
      """
      def init(_key, config) do
        {:ok, config}
      end

      defoverridable init: 2
    end
  end

  defp plug() do
    quote location: :keep do
      use Helios.Pipeline.Builder
      import Helios.Endpoint

      # Compile after the debugger so we properly wrap it.
      @before_compile Helios.Endpoint
    end
  end

  defp server() do
    quote location: :keep, unquote: false do
      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      defoverridable child_spec: 1

      @doc """
      Starts the endpoint supervision tree.
      """
      def start_link(_opts \\ []) do
        Helios.Endpoint.Supervisor.start_link(@otp_app, __MODULE__)
      end

      @doc """
      Returns the endpoint configuration for `key`

      Returns `default` if the key does not exist.
      """
      def config(key, default \\ nil) do
        case :ets.lookup(__MODULE__, key) do
          [{^key, val}] -> val
          [] -> default
        end
      end

      @doc """
      Reloads the configuration given the application environment changes.
      """
      def config_change(changed, removed) do
        Helios.Endpoint.Supervisor.config_change(__MODULE__, changed, removed)
      end
    end
  end
end
