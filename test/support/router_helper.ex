defmodule RouterHelper do
  @moduledoc """
  Conveniences for testing routers and controllers.

  Must not be used to test endpoints as it does some
  pre-processing (like fetching params) which could
  skew endpoint tests.
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

  def action(plug, verb, action, params \\ nil) do
    ctx = ctx(verb, "/", params)
    plug.call(ctx, plug.init(action))
  end
end
