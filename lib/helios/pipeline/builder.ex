defmodule Helios.Pipeline.Builder do
  @type plug :: module | atom

  @moduledoc """
  Builder for Helios pipeline
  """

  defmacro __using__(opts) do
    quote do
      @behaviour Helios.Pipeline.Plug
      @plug_builder_opts unquote(opts)

      def init(opts), do: opts

      def call(ctx, opts) do
        pipe_builder_call(ctx, opts)
      end

      defoverridable [init: 1, call: 2]

      import Helios.Pipeline.Context
      import Helios.Pipeline.Builder, only: [plug: 1, plug: 2]

      Module.register_attribute(__MODULE__, :plugs, accumulate: true)
      @before_compile Helios.Pipeline.Builder
    end
  end

  defmacro __before_compile__(env) do
    plugs        = Module.get_attribute(env.module, :plugs)
    builder_opts = Module.get_attribute(env.module, :plug_builder_opts)

    {ctx, body} = Helios.Pipeline.Builder.compile(env, plugs, builder_opts)

    quote do
      defp pipe_builder_call(unquote(ctx), _), do: unquote(body)
    end
  end

  @doc """
  A macro that stores a new plug into pipeline. `opts` will be passed unchanged to the new
  plug.
  """
  defmacro plug(plug, opts \\ []) do
    quote do
      @plugs {unquote(plug), unquote(opts), true}
    end
  end

  @doc false
  @spec compile(Macro.Env.t, [{plug, Helios.Pipeline.Plug.opts, Macro.t}], Keyword.t) :: {Macro.t, Macro.t}
  def compile(env, pipeline, builder_opts) do
    data = quote do: data
    {data, Enum.reduce(pipeline, data, &quote_plug(init_plug(&1), &2, env, builder_opts))}
  end

  defp init_plug({plug, opts, guards}) do
    case Atom.to_charlist(plug) do
      'Elixir.' ++ _ -> init_module_plug(plug, opts, guards)
      _              -> init_fun_plug(plug, opts, guards)
    end
  end

  defp init_module_plug(plug, opts, guards) do
    initialized_opts = plug.init(opts)

    if function_exported?(plug, :call, 2) do
      {:module, plug, initialized_opts, guards}
    else
      raise ArgumentError, message: "#{inspect plug} plug must implement call/2"
    end
  end

  defp init_fun_plug(plug, opts, guards) do
    {:function, plug, opts, guards}
  end

  defp quote_plug({plug_type, plug, opts, guards}, acc, env, builder_opts) do
    call = quote_plug_call(plug_type, plug, opts)

    error_message = case plug_type do
      :module   -> "expected #{inspect plug}.call/2 to return a Helios.Pipeline.Context"
      :function -> "expected #{plug}/2 to return a Helios.Pipeline.Context"
    end <> ", all plugs must receive context and return context"

    quote do
      case unquote(compile_guards(call, guards)) do
        %Helios.Pipeline.Context{halted: true} = data ->
          unquote(log_halt(plug_type, plug, env, builder_opts))
          data
        %Helios.Pipeline.Context{} = data ->
          unquote(acc)
        _ ->
          raise unquote(error_message)
      end
    end
  end

  defp quote_plug_call(:function, plug, opts) do
    quote do: unquote(plug)(data, unquote(Macro.escape(opts)))
  end

  defp quote_plug_call(:module, plug, opts) do
    quote do: unquote(plug).call(data, unquote(Macro.escape(opts)))
  end

  defp compile_guards(call, true) do
    call
  end

  defp compile_guards(call, guards) do
    quote do
      case true do
        true when unquote(guards) -> unquote(call)
        true -> data
      end
    end
  end

  defp log_halt(plug_type, plug, env, builder_opts) do
    if level = builder_opts[:log_on_halt] do
      message = case plug_type do
        :module   -> "#{inspect env.module} halted in #{inspect plug}.call/2"
        :function -> "#{inspect env.module} halted in #{inspect plug}/2"
      end

      quote do
        require Logger
        Logger.unquote(level)(unquote(message))
      end
    else
      nil
    end
  end
end
