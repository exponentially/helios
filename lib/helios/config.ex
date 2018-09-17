defmodule Helios.Config do
  # Helios configuration server.
  @moduledoc false

  use GenServer

  def start_link(module, config, defaults, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, config, defaults}, opts)
  end

  def stop(module) do
    [__config__: pid] = :ets.lookup(module, :__config__)
    GenServer.call(pid, :stop)
  end

  def merge(config1, config2) do
    Keyword.merge(config1, config2, &merger/3)
  end

  @doc "Cache a value"
  @spec cache(module, term, (module -> {:cache | :nocache, term})) :: term
  def cache(module, key, fun) do
    case :ets.lookup(module, key) do
      [{^key, :cache, val}] ->
        val

      [] ->
        case fun.(module) do
          {:cache, val} ->
            :ets.insert(module, {key, :cache, val})
            val

          {:nocache, val} ->
            val
        end
    end
  end

  @doc """
  Clear cache
  """
  @spec clear_cache(module) :: :ok
  def clear_cache(module) do
    :ets.match_delete(module, {:_, :cache, :_})
    :ok
  end

  @doc """
  Read cache
  """
  def from_env(otp_app, module, defaults) do
    merge(defaults, fetch_config(otp_app, module))
  end

  defp fetch_config(otp_app, module) do
    case Application.fetch_env(otp_app, module) do
      {:ok, conf} ->
        conf

      :error ->
        IO.puts(
          :stderr,
          "warning: no configuration found for otp_app " <>
            "#{inspect(otp_app)} and module #{inspect(module)}"
        )

        []
    end
  end

  def config_change(module, changed, removed) do
    pid = :ets.lookup_element(module, :__config__, 2)
    GenServer.call(pid, {:config_change, changed, removed})
  end

  def init({module, config, defaults}) do
    :ets.new(module, [:named_table, :public, read_concurrency: true])
    :ets.insert(module, __config__: self())
    update(module, config)
    {:ok, {module, defaults}}
  end

  def handle_call({:config_change, changed, removed}, _from, {module, defaults}) do
    cond do
      changed = changed[module] ->
        update(module, merge(defaults, changed))
        {:reply, :ok, {module, defaults}}

      module in removed ->
        stop(module, defaults)

      true ->
        {:reply, :ok, {module, defaults}}
    end
  end

  def handle_call(:stop, _from, {module, defaults}) do
    stop(module, defaults)
  end

  # Helpers

  defp merger(_k, v1, v2) do
    if Keyword.keyword?(v1) and Keyword.keyword?(v2) do
      Keyword.merge(v1, v2, &merger/3)
    else
      v2
    end
  end

  defp update(module, config) do
    old_keys = keys(:ets.tab2list(module))
    new_keys = [:__config__ | keys(config)]
    Enum.each(old_keys -- new_keys, &:ets.delete(module, &1))
    :ets.insert(module, config)
  end

  defp keys(data) do
    Enum.map(data, &elem(&1, 0))
  end

  defp stop(module, defaults) do
    :ets.delete(module)
    {:stop, :normal, :ok, {module, defaults}}
  end
end
