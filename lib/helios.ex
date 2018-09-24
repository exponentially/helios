defmodule Helios do
  @moduledoc """
  Helios application

  ## Dependencies

    * [Helios Aggregate](https://hexdocs.pm/helios_aggregate) - Aggregate pipeline and behaviour
  """

  use Application

  @doc false
  def start(_type, _args) do

    # Configure proper system flags from Helios only
    if stacktrace_depth = Application.get_env(:helios, :stacktrace_depth) do
      :erlang.system_flag(:backtrace_depth, stacktrace_depth)
    end


    children = [
      # todo: implement code reloader
      {Helios.CodeReloader.Server, []}
    ]

    opts = [strategy: :one_for_one, name: Helios.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
