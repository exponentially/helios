defmodule Helios do
  @moduledoc """
  Helios application

  ## Dependencies

    * [Helios Aggregate](https://hexdocs.pm/helios_aggregate) - Aggregate pipeline and behaviour
  """

  use Application

  @doc false
  def start(_type, _args) do
    children = [
      # todo: implement code reloader
      # {Helios.CodeReloader.Server, []}
    ]

    opts = [strategy: :one_for_one, name: Helios.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
