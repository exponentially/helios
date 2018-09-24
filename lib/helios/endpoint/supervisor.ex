defmodule Helios.Endpoint.Supervisor do
  @moduledoc false
  require Logger
  use Supervisor

  @doc false
  def start_link(otp_app, module) do
    case Supervisor.start_link(__MODULE__, {otp_app, module}, name: module) do
      {:ok, _} = ok ->
        warmup(module)
        ok

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def init({otp_app, endpoint}) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode64()

    conf =
      case endpoint.init(:supervisor, [endpoint_id: id] ++ config(otp_app, endpoint)) do
        {:ok, conf} ->
          conf

        other ->
          raise ArgumentError,
                "expected init/2 callback to return {:ok, config}, got: #{inspect(other)}"
      end

    server? = server?(conf)

    if server? and conf[:code_reloader] do
      Helios.CodeReloader.Server.check_symlinks()
    end

    children =
      []
      |> Kernel.++(config_children(endpoint, conf, otp_app))
      |> Kernel.++(server_children(endpoint, conf, server?))

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The endpoint configuration used at compile time.
  """
  def config(otp_app, endpoint) do
    Helios.Config.from_env(otp_app, endpoint, defaults(otp_app, endpoint))
  end

  @doc """
  Callback that changes the configuration from the app callback.
  """
  def config_change(endpoint, changed, removed) do
    res = Helios.Config.config_change(endpoint, changed, removed)
    warmup(endpoint)
    res
  end

  defp config_children(endpoint, conf, otp_app) do
    args = [
      endpoint,
      conf,
      defaults(otp_app, endpoint),
      [name: Module.concat(endpoint, "Config")]
    ]

    [worker(Helios.Config, args)]
  end

  defp server_children(endpoint, conf, server?) do
    if server? do
      otp_app = conf[:otp_app]

      [
        Helios.Endpoint.Handler.child_spec(otp_app, endpoint),
        Helios.Aggregate.Supervisor.child_spec(otp_app, endpoint),
        Helios.Registry.child_spec(otp_app, endpoint),
        Helios.Registry.Tracker.child_spec(otp_app, endpoint)
      ]
    else
      []
    end
  end

  defp defaults(otp_app, _module) do
    [
      otp_app: otp_app,
      adapter: Helios.Endpoint.RpcAdapter,

      # Compile-time config
      code_reloader: false,

      # Supervisor config
      pubsub: [pool_size: 1],
      watchers: []
    ]
  end

  @doc """
  Checks if Endpoint's web server has been configured to start.
  """
  def server?(otp_app, endpoint) when is_atom(otp_app) and is_atom(endpoint) do
    otp_app
    |> config(endpoint)
    |> server?()
  end

  def server?(conf) when is_list(conf) do
    Keyword.get(conf, :server, Application.get_env(:helios, :serve_endpoints, false))
  end

  defp warmup(endpoint) do
    endpoint.path("/")
    :ok
  end
end
