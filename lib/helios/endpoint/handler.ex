defmodule Helios.Endpoint.Handler do
  use GenServer
  require Logger

  def child_spec(otp_app, endpoint) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [otp_app, endpoint]},
      type: :worker
    }
  end

  def handler_name(endpoint) do
    Module.concat(endpoint, Handler)
  end

  def start_link(otp_app, endpoint, opts \\ []) do
    opts = Keyword.put(opts, :name, handler_name(endpoint))
    GenServer.start_link(__MODULE__, [otp_app, endpoint], opts)
  end

  def init([otp_app, endpoint]) do
    Logger.info("Starting handler")
    {:ok, %{endpoint: endpoint, otp_app: otp_app}}
  end
end
