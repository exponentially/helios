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
      {Task.Supervisor, name: Helios.Registry.TaskSupervisor},
      {Helios.CodeReloader.Server, []}
    ]

    opts = [strategy: :one_for_one, name: Helios.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def plug_init_mode() do
    Application.get_env(:helios, :plug_init_mode, :compile)
  end
end
