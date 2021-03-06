defmodule Helios.Aggregate.Supervisor do
  @moduledoc false
  use Supervisor

  def child_spec(otp_app, endpoint) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link, [otp_app, endpoint]},
      type: :supervisor
    }
  end

  @spec supervisor_name(atom) :: atom
  def supervisor_name(endpoint) when is_atom(endpoint) do
    Module.concat(endpoint, AggregateSupervisor)
  end

  def start_link(otp_app, endpoint) do
    opts = [name: supervisor_name(endpoint)]
    Supervisor.start_link(__MODULE__, [otp_app, endpoint], opts)
  end

  def init([_, _]) do
    children = [
      worker(Helios.Aggregate.Server, [], restart: :temporary)
    ]

    supervise(children, strategy: :simple_one_for_one)
  end

  @doc """
  Starts new plug server
  """
  def register(endpoint, plug, id) do
    server = supervisor_name(endpoint)
    {:ok, _pid} = Supervisor.start_child(server, [endpoint.__app__(), {plug, id}])
  end
end
