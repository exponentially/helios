defmodule Helios.Endpoint.Facade do
  alias Helios.Router.Route
  alias Helios.Context

  @behaviour Helios.Pipeline.Adapter

  def execute(endpoint, proxy, id, command, params \\ %{})

  def execute(endpoint, proxy, id, command, params) when is_atom(command) do
    execute(endpoint, proxy, id, Atom.to_string(command), params)
  end

  def execute(endpoint, proxy, id, command, params) do
    ctx = %Context{
      adapter: {__MODULE__, %{owner: self(), ref: make_ref(), id: id, params: params}},
      method: :execute,
      owner: self(),
      path_info: [proxy, "#{id}", command],
      params: params
    }

    endpoint.call(ctx, [])
    # todo: receive do ... end
  end

  @impl Helios.Pipeline.Adapter
  def send_resp(%{owner: _owner, ref: _ref} = state, _status, response) do
    IO.inspect("Helios.Endpoint.Facade.send_resp/3 EXECUTED!!!")
    {:ok, response, state}
  end

  def define(env, routes) do
    routes
    |> Enum.filter(fn {route, _exprs} ->
      not is_nil(route.proxy) and not (route.kind == :forward) and route.verb == :execute
    end)
    |> Enum.group_by(fn {%{proxy: proxy}, _} ->
      Module.concat([base(env.module), "Facade", Helios.Naming.camelize(proxy)])
    end)
    |> Enum.each(&defproxy(env, &1))
  end

  @anno (if :erlang.system_info(:otp_release) >= '19' do
           [generated: true]
         else
           [line: -1]
         end)

  def defproxy(env, {proxy_module, routes}) do
    proxy_ast = Enum.map(routes, fn {r, exprs} ->
      proxy_call(base(env.module), r, exprs)
    end)

    code =
      quote @anno do
        unquote(proxy_ast)
      end

    Module.create(proxy_module, code, line: env.line, file: env.file)
  end

  def proxy_call(base_name, route, %{path: path}) do
    path = Enum.take_while(path, fn e -> not is_tuple(e) end)
    path = Path.join(path)
    endpoint = Module.concat([base_name, "Endpoint"])
    quote @anno do
      @doc "Executes `#{inspect(unquote(route.opts))}` on given endpoint by calling `#{
             Atom.to_string(unquote(route.plug)) |> String.replace("Elixir.", "")
           }`"
      def unquote(route.opts)(id, params) do
        Helios.Endpoint.Facade.execute(unquote(endpoint), unquote(path), id, unquote(route.opts), params)
      end
    end
  end

  defp base(module) do
    module
    |> Module.split()
    |> List.pop_at(-1)
    |> elem(1)
    |> Module.concat()
  end
end
