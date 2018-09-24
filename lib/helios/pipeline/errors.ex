defmodule Helios.Pipeline.CommandHandlerClauseError do
  @moduledoc """
  Indicates that command handler is not implemented.

  This is runtime exception.
  """
  defexception message: nil, plug_status: :missing_command_hendler

  def exception(opts) do
    aggregate = Keyword.fetch!(opts, :aggregate)
    handler = Keyword.fetch!(opts, :handler)
    params = Keyword.fetch!(opts, :params)

    msg = """
    could not find a matching #{inspect(aggregate)}.#{handler} clause
    to execute command. This typically happens when there is a
    parameter mismatch but may also happen when any of the other
    handler arguments do not match. The command parameters are:

      #{inspect(params)}
    """

    %__MODULE__{message: msg}
  end
end

defmodule Helios.Pipeline.WrapperError do
  @moduledoc """
  Wraps catched excpetions in aggregate pipeline and rearises it so path of execution
  can easily be spotted in error log.

  This is runtime exception.
  """
  defexception [:context, :kind, :reason, :stack]

  def message(%{kind: kind, reason: reason, stack: stack}) do
    Exception.format_banner(kind, reason, stack)
  end

  @doc """
  Reraises an error or a wrapped one.
  """
  def reraise(%__MODULE__{stack: stack} = reason) do
    :erlang.raise(:error, reason, stack)
  end

  def reraise(_ctx, :error, %__MODULE__{stack: stack} = reason, _stack) do
    :erlang.raise(:error, reason, stack)
  end

  def reraise(ctx, :error, reason, stack) do
    wrapper = %__MODULE__{context: ctx, kind: :error, reason: reason, stack: stack}
    :erlang.raise(:error, wrapper, stack)
  end

  def reraise(_ctx, kind, reason, stack) do
    :erlang.raise(kind, reason, stack)
  end
end
