defmodule Helios.Endpoint.Supervisor do
  @moduledoc false
  require Logger
  use Supervisor

  @doc false
  def start_link(otp_app, module) do
    Supervisor.start_link(__MODULE__, {otp_app, module}, name: module)
  end

  @doc false
  def init({otp_app, mod}) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode64()

    conf =
      case mod.init(:supervisor, [endpoint_id: id] ++ config(otp_app, mod)) do
        {:ok, conf} ->
          conf

        other ->
          raise ArgumentError,
                "expected init/2 callback to return {:ok, config}, got: #{inspect(other)}"
      end

    server? = server?(conf)

    # if server? and conf[:code_reloader] do
    #   Helios.CodeReloader.Server.check_symlinks()
    # end

    children =
      []
      |> Kernel.++(config_children(mod, conf, otp_app))
      |> Kernel.++(server_children(mod, conf, server?))

    # |> Kernel.++(watcher_children(mod, conf, server?))

    supervise(children, strategy: :one_for_one)
  end

  defp config_children(mod, conf, otp_app) do
    args = [mod, conf, defaults(otp_app, mod), [name: Module.concat(mod, "Config")]]
    [worker(Helios.Config, args)]
  end

  defp server_children(mod, conf, server?) do
    if server? do
      server = Module.concat(mod, "Server")
      otp_app = conf[:otp_app]

      [supervisor(Helios.Endpoint.Handler, [otp_app, mod, [name: server]])]
    else
      []
    end
  end

  # defp watcher_children(_mod, conf, server?) do
  #   if server? do
  #     Enum.map(conf[:watchers], fn {cmd, args} ->
  #       worker(
  #         Helios.Endpoint.Watcher,
  #         watcher_args(cmd, args),
  #         id: {cmd, args},
  #         restart: :transient
  #       )
  #     end)
  #   else
  #     []
  #   end
  # end

  # defp watcher_args(cmd, cmd_args) do
  #   {args, opts} = Enum.split_while(cmd_args, &is_binary(&1))
  #   [cmd, args, opts]
  # end

  @doc """
  The endpoint configuration used at compile time.
  """
  def config(otp_app, endpoint) do
    Helios.Config.from_env(otp_app, endpoint, defaults(otp_app, endpoint))
  end

  defp defaults(otp_app, _module) do
    [
      otp_app: otp_app,
      handler: Helios.Endpoint.DefaultHandler,
      endpoint_name: :facade,

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
end
