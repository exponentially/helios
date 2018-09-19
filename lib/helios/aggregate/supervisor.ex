defmodule Helios.Aggregate.Supervisor do
  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    children = [
      worker(Helios.Aggregate.Server, [], restart: :temporary)
    ]

    supervise(children, strategy: :simple_one_for_one)
  end

  @doc """
  Registers a new aggregate server, and creates the worker process
  """
  def register({_, _} = aggregate_key) do
    {:ok, _pid} = Supervisor.start_child(__MODULE__, [aggregate_key])
  end
end
