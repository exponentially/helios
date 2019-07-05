defmodule Helios.Plugs.Logger do
  @moduledoc """
  Logs execution request to logger.
  """
  require Logger
  @behaviour Helios.Pipeline.Plug

  def init(opts),
    do: [
      log_level: Keyword.get(opts, :log_level, :debug)
    ]

  def call(ctx, opts) do
    log_level = Keyword.get(opts, :log_level)

    Elixir.Logger.log(log_level, fn ->
      "Executing #{inspect(ctx.private.helios_plug_handler)} at " <>
        "#{inspect(ctx.private.helios_plug)} with params: #{params(ctx.params)}"
    end)

    ctx
  end

  @doc false
  def filter_values(values, {:discard, params}), do: discard_values(values, List.wrap(params))
  def filter_values(values, {:keep, params}), do: keep_values(values, List.wrap(params))
  def filter_values(values, params), do: discard_values(values, List.wrap(params))

  defp discard_values(%{__struct__: mod} = struct, _params) when is_atom(mod) do
    struct
  end

  defp discard_values(%{} = map, params) do
    Enum.into(map, %{}, fn {k, v} ->
      if (is_atom(k) or is_binary(k)) and k in params do
        {k, "[FILTERED]"}
      else
        {k, discard_values(v, params)}
      end
    end)
  end

  defp discard_values([_ | _] = list, params) do
    Enum.map(list, &discard_values(&1, params))
  end

  defp discard_values(other, _params), do: other

  defp keep_values(%{__struct__: mod}, _params) when is_atom(mod), do: "[FILTERED]"

  defp keep_values(%{} = map, params) do
    Enum.into(map, %{}, fn {k, v} ->
      if (is_atom(k) or is_binary(k)) and k in params do
        {k, discard_values(v, [])}
      else
        {k, keep_values(v, params)}
      end
    end)
  end

  defp keep_values([_ | _] = list, params) do
    Enum.map(list, &keep_values(&1, params))
  end

  defp keep_values(_other, _params), do: "[FILTERED]"

  defp params(params) do
    filter_parameters = Application.get_env(:helios, :filter_parameters)

    params
    |> filter_values(filter_parameters)
    |> inspect()
  end
end
