defmodule Helios.Endpoint.Handler do
  @doc """
  Provides a server child specification to be started under the endpoint.
  """
  @callback child_spec(endpoint :: module, config :: keyword()) :: Supervisor.child_spec()

  use Supervisor
  require Logger

  def start_link(otp_app, endpoint, opts \\ []) do
    Supervisor.start_link(__MODULE__, {otp_app, endpoint}, opts)
  end

  @impl true
  @doc false
  def init({otp_app, endpoint}) do
    handler = endpoint.config(:handler)
    endpoint_name = endpoint.config(:endpoint_name)

    children = [
      handler.child_spec(endpoint, default([endpoint_name: endpoint_name], otp_app))
    ]

    supervise(children, strategy: :one_for_one)
  end

  defp default(config, otp_app) when is_list(config) do
    {config_keywords, config_other} = Enum.split_with(config, &keyword_item?/1)

    config_keywords =
      config_keywords
      |> Keyword.put_new(:otp_app, otp_app)

    config_keywords
    |> Kernel.++(config_other)
  end

  defp keyword_item?({key, _}) when is_atom(key), do: true
  defp keyword_item?(_), do: false
end
