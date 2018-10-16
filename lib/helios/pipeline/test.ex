defmodule Helios.Pipeline.Test do
  @moduledoc false
  defmacro __using__(_) do
    quote do
      import Helios.Pipeline.Test
      import Helios.Context
    end
  end

  alias Helios.Context

  @spec ctx(atom(), binary(), map()) :: Context.t()
  def ctx(method, path, params \\ %{}) do
    Helios.Pipeline.Adapter.Test.ctx(%Context{}, method, path, params)
  end

  @doc """
  Returns the sent response.

  This function is useful when the code being invoked crashes and
  there is a need to verify a particular response was sent even with
  the crash. It returns a tuple with `{status, headers, payload}`.
  """
  def sent_resp(%Context{adapter: {Helios.Pipeline.Adapter.Test, %{ref: ref}}}) do
    case receive_resp(ref) do
      :no_resp ->
        raise "no sent response available for the given connection. " <>
                "Maybe the application did not send anything?"

      response ->
        case receive_resp(ref) do
          :no_resp ->
            send(self(), {ref, response})
            response

          _otherwise ->
            raise "a response for the given connection has been sent more than once"
        end
    end
  end

  defp receive_resp(ref) do
    receive do
      {^ref, response} -> response
    after
      0 -> :no_resp
    end
  end


end
