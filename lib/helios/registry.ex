defmodule Helios.Registry do
  use GenServer
  alias Helios.Registry.Tracker
  import Helios.Registry.Tracker.Entry
  alias Helios.Registry.Tracker.Entry


  def child_spec(otp_app, endpoint) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,[otp_app, endpoint]},
      type: :worker
    }
  end

  def registry_name(endpoint) do
    Module.concat(endpoint, Registry)
  end

  ## Public API

  defdelegate register(endpoint, name, pid), to: Tracker, as: :track
  defdelegate register(endpoint, name, module, fun, args, timeout), to: Tracker, as: :track

  @spec unregister(module, term) :: :ok
  def unregister(endpoint, name) do
    case get_by_name(endpoint, name) do
      :undefined -> :ok
      entry(pid: pid) when is_pid(pid) -> Tracker.untrack(endpoint, pid)
    end
  end

  @spec whereis(module, term) :: :undefined | pid
  def whereis(endpoint, name) do
    case get_by_name(endpoint, name) do
      :undefined ->
        Tracker.whereis(endpoint, name)

      entry(pid: pid) when is_pid(pid) ->
        pid
    end
  end

  @spec whereis_or_register(module, term, atom(), atom(), [term]) :: {:ok, pid} | {:error, term}
  def whereis_or_register(endpoint, name, m, f, a, timeout \\ :infinity)

  @spec whereis_or_register(module, term, atom(), atom(), [term], non_neg_integer() | :infinity) ::
          {:ok, pid} | {:error, term}
  def whereis_or_register(endpoint, name, module, fun, args, timeout) do
    with :undefined <- whereis(endpoint, name),
         {:ok, pid} <- register(endpoint, name, module, fun, args, timeout) do
      {:ok, pid}
    else
      pid when is_pid(pid) ->
        {:ok, pid}

      {:error, {:already_registered, pid}} ->
        {:ok, pid}

      {:error, _} = err ->
        err
    end
  end

  @spec join(module(), term(), pid()) :: :ok
  def join(endpoint, group, pid), do: Tracker.add_meta(endpoint, group, true, pid)

  @spec leave(module(), term(), pid()) :: :ok
  defdelegate leave(endpoint, group, pid), to: Tracker, as: :remove_meta

  @spec members(endpoint :: module, group :: term) :: [pid]
  def members(endpoint, group) do
    :ets.select(registry_name(endpoint), [
      {entry(name: :"$1", pid: :"$2", ref: :"$3", meta: %{group => :"$4"}, clock: :"$5"), [],
       [:"$_"]}
    ])
    |> Enum.map(fn entry(pid: pid) -> pid end)
    |> Enum.uniq()
  end

  @spec registered(endpoint :: module) :: [{name :: term, pid}]
  defdelegate registered(endpoint), to: __MODULE__, as: :all

  @spec publish(module, term, term) :: :ok
  def publish(endpoint, group, msg) do
    for pid <- members(endpoint, group), do: Kernel.send(pid, msg)
    :ok
  end

  @spec multi_call(module, term, term, pos_integer) :: [term]
  def multi_call(endpoint, group, msg, timeout \\ 5_000) do
    Enum.map(members(endpoint, group), fn member ->
      Task.Supervisor.async_nolink(Helios.TaskSupervisor, fn ->
        GenServer.call(member, msg, timeout)
      end)
    end)
    |> Enum.map(&Task.await(&1, :infinity))
  end

  @spec send(module, name :: term, msg :: term) :: :ok
  def send(endpoint, name, msg) do
    case whereis(endpoint, name) do
      :undefined ->
        :ok

      pid when is_pid(pid) ->
        Kernel.send(pid, msg)
    end
  end

  ### Low-level ETS manipulation functions

  @spec all(module) :: [{name :: term(), pid()}]
  def all(endpoint) do
    :ets.tab2list(registry_name(endpoint))
    |> Enum.map(fn entry(name: name, pid: pid) -> {name, pid} end)
  end

  @spec snapshot(module) :: [Entry.entry()]
  def snapshot(endpoint) do
    :ets.tab2list(registry_name(endpoint))
  end

  @doc """
  Inserts a new registration, and returns true if successful, or false if not
  """
  @spec new(module, Entry.entry()) :: boolean
  def new(endpoint, entry() = reg) do
    :ets.insert_new(registry_name(endpoint), reg)
  end

  @doc """
  Like `new/1`, but raises if the insertion fails.
  """
  @spec new!(module, Entry.entry()) :: true | no_return
  def new!(endpoint, entry() = reg) do
    true = :ets.insert_new(registry_name(endpoint), reg)
  end

  @spec remove(module, Entry.entry()) :: true
  def remove(endpoint, entry() = reg) do
    :ets.delete_object(registry_name(endpoint), reg)
  end

  @spec remove_by_pid(module, pid) :: true
  def remove_by_pid(endpoint, pid) when is_pid(pid) do
    case get_by_pid(endpoint, pid) do
      :undefined ->
        true

      entries when is_list(entries) ->
        Enum.each(entries, &:ets.delete_object(registry_name(endpoint), &1))
        true
    end
  end

  @spec get_by_name(module, term()) :: :undefined | Entry.entry()
  def get_by_name(endpoint, name) do
    case :ets.lookup(registry_name(endpoint), name) do
      [] -> :undefined
      [obj] -> obj
    end
  end

  @spec get_by_pid(module, pid) :: :undefined | [Entry.entry()]
  def get_by_pid(endpoint, pid) do
    case :ets.match_object(
           registry_name(endpoint),
           entry(name: :"$1", pid: pid, ref: :"$2", meta: :"$3", clock: :"$4")
         ) do
      [] -> :undefined
      list when is_list(list) -> list
    end
  end

  @spec get_by_pid_and_name(module(), pid(), term()) :: :undefined | Entry.entry()
  def get_by_pid_and_name(endpoint, pid, name) do
    case :ets.match_object(
           registry_name(endpoint),
           entry(name: name, pid: pid, ref: :"$1", meta: :"$2", clock: :"$3")
         ) do
      [] -> :undefined
      [obj] -> obj
    end
  end

  @spec get_by_ref(module(), reference()) :: :undefined | Entry.entry()
  def get_by_ref(endpoint, ref) do
    case :ets.match_object(
           registry_name(endpoint),
           entry(name: :"$1", pid: :"$2", ref: ref, meta: :"$3", clock: :"$4")
         ) do
      [] -> :undefined
      [obj] -> obj
    end
  end

  @spec get_by_meta(module(), term()) :: :undefined | [Entry.entry()]
  def get_by_meta(endpoint, key) do
    case :ets.match_object(
           registry_name(endpoint),
           entry(name: :"$1", pid: :"$2", ref: :"$3", meta: %{key => :"$4"}, clock: :"$5")
         ) do
      [] -> :undefined
      list when is_list(list) -> list
    end
  end

  @spec get_by_meta(module(), term(), term()) :: :undefined | [Entry.entry()]
  def get_by_meta(endpoint, key, value) do
    case :ets.match_object(
           registry_name(endpoint),
           entry(name: :"$1", pid: :"$2", ref: :"$3", meta: %{key => value}, clock: :"$4")
         ) do
      [] -> :undefined
      list when is_list(list) -> list
    end
  end

  @spec reduce(module(), term(), (Entry.entry(), term() -> term())) :: term()
  def reduce(endpoint, acc, fun) when is_function(fun, 2) do
    :ets.foldl(fun, acc, registry_name(endpoint))
  end

  @spec update(module(), term(), Keyword.t()) :: boolean
  defmacro update(endpoint, key, updates) do
    fields = Enum.map(updates, fn {k, v} -> {Entry.index(k) + 1, v} end)

    quote bind_quoted: [endpoint: endpoint, key: key, fields: fields] do
      :ets.update_element(Helios.Registry.registry_name(endpoint), key, fields)
    end
  end

  ## GenServer Implementation

  def start_link(otp_app, endpoint) do
    opts = [name: registry_name(endpoint)]
    GenServer.start_link(__MODULE__, [otp_app, endpoint], opts)
  end

  def init([otp_app, endpoint]) do
    table_name = registry_name(endpoint)
    table =
      :ets.new(table_name, [
        :set,
        :named_table,
        :public,
        keypos: 2,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table_name: table_name, endpoint: endpoint, otp_app: otp_app, registry: table}}
  end
end
