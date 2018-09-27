defmodule Helios.Pipeline do
  @moduledoc false

  alias Helios.Context

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Helios.Pipeline.Plug

      import Helios.Pipeline
      alias Helios.Context

      Module.register_attribute(__MODULE__, :plugs, accumulate: true)
      @before_compile Helios.Pipeline
      @helios_log_level Keyword.get(opts, :log, :debug)

      @doc false
      def init(opts), do: opts

      @doc false
      def call(ctx, handler) when is_atom(handler) do
        ctx =
          update_in(
            ctx.private,
            fn private ->
              private
              |> Map.put(:helios_plug, __MODULE__)
              |> Map.put(:helios_plug_handler, handler)
            end
          )
          |> Map.put(:status, :executing)

        helios_plug_pipeline(ctx, handler)
      end

      @doc false
      def handle(%Context{private: %{helios_plug_handler: handler}} = ctx, _ops) do
        apply(__MODULE__, handler, [ctx, ctx.params])
      end

      defoverridable init: 1, call: 2, handle: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    handler = {:handle, [], true}
    plugs = [handler | Module.get_attribute(env.module, :plugs)]

    {ctx, body} =
      Helios.Pipeline.Builder.compile(
        env,
        plugs,
        log_on_halt: :debug,
        init_mode: Helios.plug_init_mode()
      )

    quote do
      defoverridable handle: 2

      def handle(var!(ctx_before), opts) do
        try do
          # var!(ctx_after) = super(var!(ctx_before), opts)
          super(var!(ctx_before), opts)
        catch
          :error, reason ->
            Helios.Pipeline.__catch__(
              var!(ctx_before),
              reason,
              __MODULE__,
              var!(ctx_before).private.helios_plug_handler,
              System.stacktrace()
            )
        end
      end

      defp helios_plug_pipeline(unquote(ctx), var!(handler)) do
        var!(ctx) = unquote(ctx)
        var!(plug) = __MODULE__
        _ = var!(ctx)
        _ = var!(plug)
        _ = var!(handler)

        unquote(body)
      end
    end
  end

  @doc false
  def __catch__(
        %Helios.Context{},
        :function_clause,
        plug,
        handler,
        [{plug, handler, [%Helios.Context{} = ctx | _], _loc} | _] = stack
      ) do
    args = [plug: plug, handler: handler, params: ctx.params]
    reraise Helios.Pipeline.MessageHandlerClauseError, args, stack
  end

  def __catch__(%Context{} = ctx, reason, _aggregate, _handler, stack) do
    Helios.Pipeline.WrapperError.reraise(ctx, :error, reason, stack)
  end

  @doc """
  Stores a plug to be executed as part of the command pipeline.
  """
  defmacro plug(plug)

  defmacro plug({:when, _, [plug, guards]}), do: plug(plug, [], guards)

  defmacro plug(plug), do: plug(plug, [], true)

  @doc """
  Stores a plug with the given options to be executed as part of
  the command pipeline.
  """
  defmacro plug(plug, opts)

  defmacro plug(plug, {:when, _, [opts, guards]}), do: plug(plug, opts, guards)

  defmacro plug(plug, opts), do: plug(plug, opts, true)

  defp plug(plug, opts, guards) do
    quote do
      @plugs {unquote(plug), unquote(opts), unquote(Macro.escape(guards))}
    end
  end
end
