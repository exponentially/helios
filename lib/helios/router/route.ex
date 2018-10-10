defmodule Helios.Router.Route do
  @moduledoc false
  alias Helios.Router.Route

  @type verb :: :execute | :process | :trace
  @type line :: non_neg_integer()
  @type kind :: :match | :forward
  @type path :: String.t()
  @type plug :: atom()
  @type opts :: list()
  @type proxy :: {atom(), atom()} | atom() | nil
  @type private :: map()
  @type assigns :: map()
  @type pipe_through :: list(atom())
  @type t :: %Route{
          verb: verb,
          line: line,
          kind: kind,
          path: path,
          plug: plug,
          opts: opts,
          proxy: proxy,
          private: private,
          assigns: assigns,
          pipe_through: pipe_through
        }

  @doc """
  The `Helios.Router.Route` struct stores:

    * `:type` - message type as an atom
    * `:line` - the line the route was defined in source code
    * `:kind` - the kind of route, one of `:match`, `:forward`
    * `:path` - the normalized path as string
    * `:plug` - the plug module
    * `:opts` - the plug options
    * `:proxy` - the name of the proxy helper as a {atom, atom}, atom or may be nil
    * `:private` - the private route info
    * `:assigns` - the route info
    * `:pipe_through` - the pipeline names as a list of atoms

  """
  defstruct [:verb, :line, :kind, :path, :plug, :opts, :proxy, :private, :assigns, :pipe_through]

  @doc "Used as a plug on forwarding"
  def init(opts), do: opts

  @doc "Used as a plug on forwarding"
  def call(%{path_info: path} = ctx, {fwd_segments, plug, opts}) do
    new_path = path -- fwd_segments
    {_, ^new_path} = Enum.split(path, length(path) - length(new_path))
    ctx = %{ctx | path_info: new_path}
    ctx = plug.call(ctx, plug.init(opts))
    %{ctx | path_info: path}
  end

  @doc """
  Receives the verb, path, plug, options and proxy helper
  and returns a `Helios.Router.Route` struct.
  """
  @spec build(line, kind, verb, path | nil, plug, opts, proxy, pipe_through | nil, %{}, %{}) :: t
  def build(line, kind, verb, path, plug, opts, proxy, pipe_through, private, assigns)
      when is_atom(verb) and is_atom(plug) and (is_nil(proxy) or is_binary(proxy)) and
             is_list(pipe_through) and is_map(private) and is_map(assigns) and
             kind in [:match, :forward] do

    %Route{
      verb: verb,
      line: line,
      kind: kind,
      path: path,
      plug: plug,
      opts: opts,
      proxy: proxy,
      private: private,
      assigns: assigns,
      pipe_through: pipe_through
    }
  end

  @doc """
  Builds the compiled expressions used by the route.
  """
  def exprs(route) do
    {path, binding} = build_path_and_binding(route)

    %{
      path: path,
      verb_match: verb_match(route.verb),
      binding: binding,
      prepare: build_prepare(route, binding),
      dispatch: build_dispatch(route)
    }
  end

  defp verb_match(:*), do: Macro.var(:_verb, nil)
  defp verb_match(verb), do: verb

  defp build_path_and_binding(%Route{path: path} = route) do
    {params, segments} =
      case route.kind do
        :forward -> build_path_match(path <> "/*_forward_path_info")
        :match -> build_path_match(path)
      end

    binding =
      for var <- params, var != :_forward_path_info do
        {Atom.to_string(var), Macro.var(var, nil)}
      end

    {segments, binding}
  end

  defp build_prepare(route, binding) do
    {static_data, match_params, merge_params} = build_params(binding)
    {match_private, merge_private} = build_prepare_expr(:private, route.private)
    {match_assigns, merge_assigns} = build_prepare_expr(:assigns, route.assigns)

    match_all = match_params ++ match_private ++ match_assigns
    merge_all = merge_params ++ merge_private ++ merge_assigns

    if merge_all != [] do
      quote do
        unquote_splicing(static_data)
        %{unquote_splicing(match_all)} = var!(ctx)
        %{var!(ctx) | unquote_splicing(merge_all)}
      end
    else
      quote do
        var!(ctx)
      end
    end
  end

  defp build_dispatch(%Route{kind: :forward} = route) do
    {_params, fwd_segments} = build_path_match(route.path)

    quote do
      {Helios.Router.Route, {unquote(fwd_segments), unquote(route.plug), unquote(route.opts)}}
    end
  end

  defp build_dispatch(%Route{} = route) do
    quote do
      {unquote(route.plug), unquote(route.opts)}
    end
  end

  defp build_prepare_expr(_key, data) when data == %{}, do: {[], []}

  defp build_prepare_expr(key, data) do
    var = Macro.var(key, :ctx)
    merge = quote(do: Map.merge(unquote(var), unquote(Macro.escape(data))))
    {[{key, var}], [{key, merge}]}
  end

  defp build_params([]), do: {[], [], []}

  defp build_params(binding) do
    params = Macro.var(:params, :ctx)
    path_params = Macro.var(:path_params, :ctx)
    merge_params = quote(do: Map.merge(unquote(params), unquote(path_params)))
    {
      [quote(do: unquote(path_params) = %{unquote_splicing(binding)})],
      [{:params, params}],
      [{:params, merge_params}, {:path_params, path_params}]
    }
  end

  @doc """
  Validates and returns the list of forward path segments.

  Raises `RuntimeError` if the `plug` is already forwarded or the
  `path` contains a dynamic segment.
  """
  def forward_path_segments(path, plug, helios_forwards) do
    case build_path_match(path) do
      {[], path_segments} ->
        if helios_forwards[plug] do
          raise ArgumentError,
                "#{inspect(plug)} has already been forwarded to. A module can only be forwarded a single time."
        end

        path_segments

      _ ->
        raise ArgumentError,
              "dynamic segment \"#{path}\" not allowed when forwarding. Use a static path instead."
    end
  end

  defdelegate build_path_match(path), to: Helios.Router.Utils
end
