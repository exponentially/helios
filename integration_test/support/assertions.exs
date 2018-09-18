defmodule Helios.Integration.Assertions do
  @moduledoc """
  Assertions macros that should make testing aggregates easier.
  """
  alias Helios.Pipeline.Context

  @doc """
  Asserts is given event/events are emmitted during pipeline execution
  """
  @spec assert_emitted(Context.t(), map() | [map()]) :: Context.t()
  defmacro assert_emitted(ctx, event) do
    quote do
      require ExUnit.Assertions
      events = List.wrap(unquote(event))

      emitted_events = List.wrap(unquote(ctx).events)

      events_length = length(events)
      emmited_length = length(emitted_events)

      ExUnit.Assertions.assert(
        events_length == emmited_length,
        "number of emmited events [#{emmited_length}] mismatch expected length [#{events_length}]"
      )

      Enum.zip([events, emitted_events])
      |> Enum.each(fn {event, emitted} ->
        ExUnit.Assertions.assert(
          event.type == emitted.type,
          "Expected event type `#{event.type}` do not match emitted `#{emitted.type}`"
        )

        ExUnit.Assertions.assert(
          event.data == emitted.data,
          "Expected event type `#{event.type}` do not match emitted `#{emitted.type}`"
        )
      end)
    end
  end

  @doc """
  Asserts if given response is set during pipeline execution
  """
  @spec assert_response(ctx :: Context.t(), event :: struct()) :: Context.t()
  defmacro assert_response(ctx, response) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert(%{response: unquote(response)} = unquote(ctx))
    end
  end

  @doc """
  If `is_haleted` argument is set to true it will assert if given context is halted,
  otherwise it will pass if given context is not halted
  """
  @spec assert_halted(ctx :: Context.t(), is_halted :: boolean) :: Context.t()
  defmacro assert_halted(ctx, is_halted \\ true) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert(unquote(ctx).halted == unquote(is_halted))
    end
  end
end
