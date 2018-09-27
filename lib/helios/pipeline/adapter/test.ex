defmodule Helios.Pipeline.Adapter.Test do
  @moduledoc false
  @behaviour Helios.Pipeline.Adapter
  alias Helios.Context

  @already_sent {:plug_ctx, :sent}

  def ctx(%Context{} = ctx, method, uri, params) when method in [:execute, :trace, :process] do
    maybe_flush()

    uri = URI.parse(uri)
    owner = self()

    state = %{
      method: method,
      params: params,
      ref: make_ref(),
      owner: owner
    }

    %{
      ctx
      | adapter: {__MODULE__, state},
        method: method,
        params: params,
        path_info: split_path(uri.path)
    }
  end

  def send_resp(%{owner: owner, ref: ref} = state, status, payload) do
    send(owner, {ref, status, payload})
    {:ok, payload, state}
  end

  defp maybe_flush() do
    receive do
      @already_sent -> :ok
    after
      0 -> :ok
    end
  end

  defp split_path(nil), do: []

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    for segment <- segments, segment != "", do: segment
  end
end
