defmodule Helios.Endpoint.DefaultHandler do
  @behaviour Helios.Endpoint.Handler
  require Logger

  use GenServer

  @doc """
  Generates a childspec to be used in the supervision tree.
  """
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

  def init({endpoint, config}) do
    {:ok,
     %{
       endpoint: endpoint,
       config: config
     }}
  end

  def handle_call({:execute, command, metadata}, from, state) do

  end

end
