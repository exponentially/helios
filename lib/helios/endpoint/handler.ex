defmodule Helios.Endpoint.Handler do
  @moduledoc false
  use GenServer
  use Helios.Logger

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
    info(fn -> "[endpoint: #{inspect(endpoint)}] Starting message handler" end)
    {:ok, %{endpoint: endpoint, otp_app: otp_app}}
  end
end
