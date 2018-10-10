defmodule Helios.Router do
  defmodule NoRouteError do
    @moduledoc """
    Exception raised when no route is found.
    """
    defexception plug_status: :not_found, message: "no route found", ctx: nil, router: nil

    def exception(opts) do
      ctx = Keyword.fetch!(opts, :ctx)
      router = Keyword.fetch!(opts, :router)
      path = "/" <> Enum.join(ctx.path_info, "/")

      %NoRouteError{
        message: "no route found for #{ctx.method} #{path} (#{inspect(router)})",
        ctx: ctx,
        router: router
      }
    end
  end

  @moduledoc """
  Helios router module. When used in onther module, developer can define mappings
  for paths that are assigned to specific aggregate implementation.
  This mapping will be translated to routing logic that will help execute
  aggregate commands in `Helios.Pipeline`.

  As in case of Helios.Aggregate, router too can have plugs, that will be executed in
  specified order before or after aggregate pipeline is executed.

  ### Example

      defmodule MyApp.Router do
        use Helios.Router

        pipeline :secured do
          plug MyApp.Plugs.Authotization
        end

        aggregate "/users", MyApp.Aggregates.UserAggregate, only: [
          :create_user,
          :enable_login,
          :set_password
        ]

        aggregate "/registrations", MyApp.Aggregates.Registration,
          param: :correlation_id,
          only: [
            :create,
            :confirm_email,
            :complete_registration
          ]

        subscribe "ce-users", MyApp.ProcessManagers.UserRegistration, to: [
                  {MyApp.Events.UserCreated, :registration_id},
                  {MyApp.Events.RegistrationStarted, :registration_id},
                  {MyApp.Events.EmailConfirmed, :registration_id},
                  {MyApp.Events.LoginEnabled, :correlation_id}
                  {MyApp.Events.PasswordInitialized, :correlation_id}
                ]
        end

        scope "/", MyApp.Aggregates do
          pipe_through :secured

          aggregate "/users", UserAggregate, only: [
            :reset_password,
            :change_profile
          ]
        end
      end
  """

  alias Helios.Context
  alias Helios.Router.Scope
  alias Helios.Router.Route
  alias Helios.Router.Aggregate
  # alias Helios.Router.Subscription

  @methods [:execute, :process, :trace]

  @doc false
  defmacro __using__(_) do
    quote do
      unquote(prelude())
      unquote(defs())
      unquote(match_dispatch())
    end
  end

  defp prelude() do
    quote do
      Module.register_attribute(__MODULE__, :helios_routes, accumulate: true)
      @helios_forwards %{}
      import Helios.Router

      # Set up initial scope
      @helios_pipeline nil
      Helios.Router.Scope.init(__MODULE__)
      @before_compile unquote(__MODULE__)
    end
  end

  defp defs() do
    quote unquote: false do
      var!(add_aggregate, Helios.Router) = fn spec ->
        path = spec.path
        aggr = spec.aggregate
        opts = spec.route

        Enum.each(spec.commands, fn
          command ->
            p =
              if spec.singleton do
                Path.join([spec.path, Atom.to_string(command)])
              else
                Path.join([spec.path, ":#{spec.param}", Atom.to_string(command)])
              end

            execute(p, aggr, command, opts)

          command ->
            nil
        end)
      end
    end
  end

  @doc false
  def __call__(
        {%Context{private: %{helios_router: router, helios_bypass: {router, pipes}}} = ctx,
         _pipeline, _dispatch}
      ) do
    Enum.reduce(pipes, ctx, fn pipe, acc -> apply(router, pipe, [acc, []]) end)
  end

  def __call__({%Context{private: %{helios_bypass: :all}} = ctx, _pipeline, _dispatch}) do
    ctx
  end

  def __call__({ctx, pipeline, {plug, opts}}) do
    case pipeline.(ctx) do
      %Context{halted: true} = halted_ctx ->
        halted_ctx

      %Context{} = piped_ctx ->
        try do
          case piped_ctx.method do
            :execute ->
              piped_ctx
              |> Context.put_private(:helios_plug, plug)
              |> Context.put_private(:helios_plug_handler, plug.init(opts))
              |> Helios.Aggregate.Server.call(plug.init(opts))

            :process ->
              plug.call(piped_ctx, plug.init(opts))

            _ ->
              throw({:error, :unsuported_method})
          end
        rescue
          e in Helios.Pipeline.WrapperError ->
            Helios.Pipeline.WrapperError.reraise(e)
        catch
          :error, reason ->
            Helios.Pipeline.WrapperError.reraise(piped_ctx, :error, reason, System.stacktrace())
        end
    end
  end

  def match_dispatch() do
    quote location: :keep do
      @behaviour Helios.Pipeline.Plug

      @doc """
      Callback required by Pipeline that initializes the router
      for serving web requests.
      """
      def init(opts) do
        opts
      end

      @doc """
      Callback invoked by Pipeline on every request.
      """
      def call(ctx, _opts) do
        ctx
        |> prepare()
        |> __match_route__(ctx.method, Enum.map(ctx.path_info, &URI.decode/1))
        |> Helios.Router.__call__()
      end

      defoverridable init: 1, call: 2
    end
  end

  @anno (if :erlang.system_info(:otp_release) >= '19' do
           [generated: true]
         else
           [line: -1]
         end)

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:helios_routes)
      |> Enum.reverse()

    routes_with_exprs = Enum.map(routes, &{&1, Route.exprs(&1)})

    Helios.Endpoint.Facade.define(env, routes_with_exprs)

    {matches, _} = Enum.map_reduce(routes_with_exprs, %{}, &build_match/2)

    # @anno is used here to avoid warnings if forwarding to root path
    match_404 =
      quote @anno do
        def __match_route__(ctx, _method, _path_info) do
          raise NoRouteError, ctx: ctx, router: __MODULE__
        end
      end

    quote do
      @doc false
      def __routes__, do: unquote(Macro.escape(routes))

      @doc false
      def __helpers__, do: __MODULE__.Helpers

      defp prepare(ctx) do
        update_in(
          ctx.private,
          &(&1
            |> Map.put(:helios_router, __MODULE__)
            |> Map.put(__MODULE__, {Map.get(ctx, :script_path), @helios_forwards}))
        )
      end

      unquote(matches)
      unquote(match_404)
    end
  end

  defp build_match({route, exprs}, known_pipelines) do
    %{pipe_through: pipe_through} = route

    %{
      prepare: prepare,
      dispatch: dispatch,
      verb_match: verb_match,
      path: path
    } = exprs

    {pipe_name, pipe_definition, known_pipelines} =
      case known_pipelines do
        %{^pipe_through => name} ->
          {name, :ok, known_pipelines}

        %{} ->
          name = :"__pipe_through#{map_size(known_pipelines)}__"
          {name, build_pipes(name, pipe_through), Map.put(known_pipelines, pipe_through, name)}
      end

    quoted =
      quote line: route.line do
        unquote(pipe_definition)

        @doc false
        def __match_route__(var!(ctx), unquote(verb_match), unquote(path)) do
          {unquote(prepare), &(unquote(Macro.var(pipe_name, __MODULE__)) / 1), unquote(dispatch)}
        end
      end

    {quoted, known_pipelines}
  end

  defp build_pipes(name, []) do
    quote do
      defp unquote(name)(ctx) do
        Helios.Context.put_private(ctx, :helios_pipelines, [])
      end
    end
  end

  defp build_pipes(name, pipe_through) do
    plugs = pipe_through |> Enum.reverse() |> Enum.map(&{&1, [], true})

    {ctx, body} =
      Helios.Pipeline.Builder.compile(__ENV__, plugs, init_mode: Helios.plug_init_mode())

    quote do
      defp unquote(name)(unquote(ctx)) do
        unquote(ctx) =
          Helios.Context.put_private(
            unquote(ctx),
            :helios_pipelines,
            unquote(pipe_through)
          )

        unquote(body)
      end
    end
  end

  defmacro match(verb, path, plug, plug_opts, options \\ []) do
    add_route(:match, verb, path, plug, plug_opts, options)
  end

  for verb <- @methods do
    @doc """
    Generates a route to handle a `:#{verb}` request to the given path.
    """
    defmacro unquote(verb)(path, plug, plug_opts, options \\ []) do
      add_route(:match, unquote(verb), path, plug, plug_opts, options)
    end
  end

  defp add_route(kind, verb, path, plug, plug_opts, options) do
    quote do
      @helios_routes Scope.route(
                       __ENV__.line,
                       __ENV__.module,
                       unquote(kind),
                       unquote(verb),
                       unquote(path),
                       unquote(plug),
                       unquote(plug_opts),
                       unquote(options)
                     )
    end
  end

  @doc """
  Defines a context pipeline.

  Pipelines are defined at the router root and can be used
  from any scope.

  ## Examples

      pipeline :secured do
        plug :token_authentication
        plug :dispatch
      end

  A scope may then use this pipeline as:

      scope "/" do
        pipe_through :secured
      end

  Every time `pipe_through/1` is called, the new pipelines
  are appended to the ones previously given.
  """
  defmacro pipeline(plug, do: block) do
    block =
      quote do
        plug = unquote(plug)
        @helios_pipeline []
        unquote(block)
      end

    compiler =
      quote unquote: false do
        Scope.pipeline(__MODULE__, plug)

        {ctx, body} =
          Helios.Pipeline.Builder.compile(
            __ENV__,
            @helios_pipeline,
            init_mode: Helios.plug_init_mode()
          )

        def unquote(plug)(unquote(ctx), _) do
          try do
            unquote(body)
          rescue
            e in Helios.Pipeline.WrapperError ->
              Helios.Pipeline.WrapperError.reraise(e)
          catch
            :error, reason ->
              Helios.Pipeline.WrapperError.reraise(
                unquote(ctx),
                :error,
                reason,
                System.stacktrace()
              )
          end
        end

        @helios_pipeline nil
      end

    quote do
      try do
        unquote(block)
        unquote(compiler)
      after
        :ok
      end
    end
  end

  @doc """
  Defines a plug inside a pipeline.

  See `pipeline/2` for more information.
  """
  defmacro plug(plug, opts \\ []) do
    quote do
      if pipeline = @helios_pipeline do
        @helios_pipeline [{unquote(plug), unquote(opts), true} | pipeline]
      else
        raise "cannot define plug at the router level, plug must be defined inside a pipeline"
      end
    end
  end

  @doc """
  Defines a pipeline to send the context through.

  See `pipeline/2` for more information.
  """
  defmacro pipe_through(pipes) do
    quote do
      if pipeline = @helios_pipeline do
        raise "cannot pipe_through inside a pipeline"
      else
        Scope.pipe_through(__MODULE__, unquote(pipes))
      end
    end
  end

  # Aggregate mactos

  defmacro aggregate(path, aggregate, opts, do: nested_context) do
    add_aggregate(path, aggregate, opts, do: nested_context)
  end

  @doc """
  See `aggregate/4`.
  """
  defmacro aggregate(path, aggregate, do: nested_context) do
    IO.warn("""
    No command names are given, compiler will inject "any" command to route using `only: ["*"]`.
    """)

    add_aggregate(path, aggregate, [], do: nested_context)
  end

  defmacro aggregate(path, aggregate, opts) do
    add_aggregate(path, aggregate, opts, do: nil)
  end

  @doc """
  See `aggregate/4`.
  """
  defmacro aggregate(path, aggregate) do
    add_aggregate(path, aggregate, [], do: nil)
  end

  defp add_aggregate(path, aggregate, options, do: context) do
    scope =
      if context do
        quote do
          scope(aggregate.member, do: unquote(context))
        end
      end

    quote do
      aggregate = Aggregate.build(unquote(path), unquote(aggregate), unquote(options))
      var!(add_aggregate, Helios.Router).(aggregate)
      unquote(scope)
    end
  end

  @doc """
  Defines a scope in which routes can be nested.

  ## Examples

      scope path: "/api/v1", as: :api_v1, alias: API.V1 do
        aggregate "/users", UserAggregate
      end

  The generated route above will match on the path `"/api/v1/users/:id/*"`
  and will dispatch to any command to `API.V1.UserAggregate`.

  ## Options

  The supported options are:

    * `:path` - a string containing the path scope
    * `:as` - a string or atom containing the named helper scope
    * `:alias` - an alias (atom) containing the module namespace scope
    * `:private` - a map of private data to merge into the context when a route matches
    * `:assigns` - a map of data to merge into the context when a route matches

  """
  defmacro scope(options, do: context) do
    do_scope(options, context)
  end

  @doc """
  Define a scope with the given path.

  This function is a shortcut for:

      scope path: path do
        ...
      end

  ## Examples

      scope "/api/v1", as: :api_v1, alias: API.V1 do
        aggregate "/users", UserAggregate
      end

  """
  defmacro scope(path, options, do: context) do
    options =
      quote do
        path = unquote(path)

        case unquote(options) do
          alias when is_atom(alias) -> [path: path, alias: alias]
          options when is_list(options) -> Keyword.put(options, :path, path)
        end
      end

    do_scope(options, context)
  end

  @doc """
  Defines a scope with the given path and alias.

  This function is a shortcut for:

      scope path: path, alias: alias do
        ...
      end

  ## Examples

      scope "/api/v1", API.V1, as: :api_v1 do
        aggregate "/users", UserAggregate
      end

  """
  defmacro scope(path, alias, options, do: context) do
    options =
      quote do
        unquote(options)
        |> Keyword.put(:path, unquote(path))
        |> Keyword.put(:alias, unquote(alias))
      end

    do_scope(options, context)
  end

  defp do_scope(options, context) do
    quote do
      Scope.push(__MODULE__, unquote(options))

      try do
        unquote(context)
      after
        Scope.pop(__MODULE__)
      end
    end
  end

  @doc """
  Forwards a request at the given path to a plug.

  All paths that match the forwarded prefix will be sent to
  the forwarded plug. This is useful for sharing a router between
  applications or even breaking a big router into smaller ones.
  The router pipelines will be invoked prior to forwarding the
  connection.

  The forwarded plug will be initialized at compile time.

  Note, however, that we don't advise forwarding to another
  endpoint. The reason is that plugs defined by your app
  and the forwarded endpoint would be invoked twice, which
  may lead to errors.

  ## Examples

      scope "/", MyApp do
        pipe_through [:secured, :admin]

        forward "/admin", SomeLib.SomePlug
        forward "/transactions", TransactionsRouter
      end

  """
  defmacro forward(path, plug, plug_opts \\ [], router_opts \\ []) do
    router_opts = Keyword.put(router_opts, :as, nil)

    quote unquote: true, bind_quoted: [path: path, plug: plug] do
      plug = Scope.register_forwards(__MODULE__, path, plug)
      unquote(add_route(:forward, :*, path, plug, plug_opts, router_opts))
    end
  end
end
