defmodule Helios.Endpoint.DefaultHandler do
  @moduledoc """
  Default `Helios.Endpoint` message handler. Each message (command) comes to this
  handler and then it is dispatched to internal processes.

  If you, for instance need to plug rabbitmq as a transport, and need to translate
  messages to pipeline context, please implement `Helios.Endpoint.Handler` behaviour
  and replace default one in configuration.

  ## Example
    use Mix.Config

    config :my_app, MyApp.Endpoint,
      handler: MyApp.RabbitMqHandler

  """
  use GenServer
  require Logger
  @behaviour Helios.Endpoint.Handler

  @doc """
  Generates a childspec to be used in the supervision tree.
  """
  @impl true
  def child_spec(endpoint, config) do
    opts = [name: Keyword.get(config, :endpoint_name)]
    args = [endpoint, config, opts]

    %{
      id: Helios.Endpoint.DefaultHandler,
      start: {Helios.Endpoint.DefaultHandler, :start_link, args},
      type: :worker
    }
  end

  def start_link(endpoint, config) do
    GenServer.start_link(__MODULE__, {endpoint, config}, name: __MODULE__)
  end

  @impl true
  def init({endpoint, config}) do
    {:ok,
     %{
       endpoint: endpoint,
       config: config
     }}
  end
end
