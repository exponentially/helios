defmodule Helios.Endpoint.Facade do
  @moduledoc false
  alias Helios.Context
  @behaviour Helios.Pipeline.Adapter

  def ctx(%{path: path, params: params}) do
    ref = make_ref()

    req = %{
      owner: self(),
      ref: ref,
      path: path,
      params: params
    }

    %Context{
      adapter: {__MODULE__, req},
      method: :execute,
      owner: self(),
      path_info: split_path(path),
      params: params
    }
  end

  @doc "Executes command at given proxy and endpoint"
  @spec execute(module, String.t(), term, atom | String.t(), map(), Keyword.t()) :: term
  def execute(endpoint, proxy, id, command, params \\ %{}, opts \\ [])

  def execute(endpoint, proxy, id, command, params, opts) when is_atom(command) do
    execute(endpoint, proxy, id, Atom.to_string(command), params, opts)
  end

  def execute(endpoint, proxy, id, command, params, opts) do
    proxy_id = to_param(id)
    opts = Keyword.put_new(opts, :timeout, 5_000)
    path = Path.join([proxy, proxy_id, command])

    %{path_info: path_info} = ctx = ctx(%{path: path, params: params})

    try do
      case endpoint.__dispatch__(path_info, opts) do
        {:plug, handler, opts} ->
          ctx
          |> handler.call(opts)
          |> maybe_respond()
      end
    catch
      :error, value ->
        stack = System.stacktrace()
        exception = Exception.normalize(:error, value, stack)
        exit({{exception, stack}, {endpoint, :call, [ctx, opts]}})

      :throw, value ->
        stack = System.stacktrace()
        exit({{{:nocatch, value}, stack}, {endpoint, :call, [ctx, opts]}})

      :exit, value ->
        exit({value, {endpoint, :call, [ctx, opts]}})
    end
  end

  @impl Helios.Pipeline.Adapter
  def send_resp(%{owner: _owner, ref: _ref} = state, _status, response) do
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
    proxy_ast =
      Enum.map(routes, fn {r, exprs} ->
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
      @spec unquote(route.opts)(id :: term, params :: map(), Keyword.t()) :: {:ok | :error, term}
      def unquote(route.opts)(id, params, opts \\ []) do
        Helios.Endpoint.Facade.execute(
          unquote(endpoint),
          unquote(path),
          id,
          unquote(route.opts),
          params,
          opts
        )
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

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    for segment <- segments, segment != "", do: segment
  end

  defp to_param(int) when is_integer(int), do: Integer.to_string(int)
  defp to_param(bin) when is_binary(bin), do: bin
  defp to_param(false), do: "false"
  defp to_param(true), do: "true"
  defp to_param(data), do: Helios.Param.to_param(data)

  defp maybe_respond({:exit, {:timeout, _}}) do
    {:error, :timeout}
  end

  defp maybe_respond(%Context{status: :success, response: resp}) do
    {:ok, resp}
  end

  defp maybe_respond(%Context{status: :failed, response: resp}) do
    {:error, resp}
  end
end
