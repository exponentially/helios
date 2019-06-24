defmodule RouterHelper do
  @moduledoc """
  Conveniences for testing routers and aggregates.
  """

  import Helios.Pipeline.Test

  defmacro __using__(_) do
    quote do
      use Helios.Pipeline.Test
      import RouterHelper
    end
  end

  def call(router, verb, path, params \\ nil, script_name \\ []) do
    verb
    |> ctx(path, params)
    |> Map.put(:script_name, script_name)
    |> router.call(router.init([]))
  end

  def execute(plug, handler, params \\ nil) do
    :execute
    |> ctx("/", params)
    |> Helios.Context.put_private(:helios_plug, plug)
    |> Helios.Context.put_private(:helios_plug_handler, handler)
    |> plug.call(plug.init(handler))
  end
end
