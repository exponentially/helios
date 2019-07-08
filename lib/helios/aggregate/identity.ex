defmodule Helios.Aggregate.Identity do
  @doc """
  When implemented, it should generate unique identity for aggregate
  """
  @callback generate(opts :: keyword) :: term

  defmacro __using__(_) do
    quote do
      @behaviour Helios.Aggregate.Identity
    end
  end
end
