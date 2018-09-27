defmodule Helios.Pipeline.Adapter.Rpc do
  use GenServer

  def start_link(client, plug, config) do
    GenServer.start_link(__MODULE__, {client, plug, config})
  end


  def init({client, plug, config}) do
    {:ok, %{
      client: client,
      plug: plug,
      config: config
    }}
  end



end
