defmodule Helios.Router.InvalidSpecError do
  defexception message: "invalid route specification"
end

defmodule Helios.Router.Utils do

  @moduledoc false

  @doc """
  Generates a representation that will only match routes
  according to the given `spec`.

  If a non-binary spec is given, it is assumed to be
  custom match arguments and they are simply returned.

  ## Examples

      iex> Helios.Router.Utils.build_path_match("/foo/:id")
      {[:id], ["foo", {:id, [], nil}]}

  """
  def build_path_match(spec, context \\ nil) when is_binary(spec) do
    build_path_match(split(spec), context, [], [])
  end

  @doc """
  Builds a list of path param names and var match pairs that can bind
  to dynamic path segment values. Excludes params with underscores;
  otherwise, the compiler will warn about used underscored variables
  when they are unquoted in the macro.

  ## Examples

      iex> Helios.Router.Utils.build_path_params_match([:id])
      [{"id", {:id, [], nil}}]
  """
  def build_path_params_match(vars) do
    vars
    |> Enum.map(fn v -> {Atom.to_string(v), Macro.var(v, nil)} end)
    |> Enum.reject(fn v -> match?({"_" <> _var, _macro}, v) end)
  end

  @doc """
  Splits the given path into several segments.
  It ignores both leading and trailing slashes in the path.

  ## Examples

      iex> Helios.Router.Utils.split("/foo/bar")
      ["foo", "bar"]

      iex> Helios.Router.Utils.split("/:id/*")
      [":id", "*"]

      iex> Helios.Router.Utils.split("/foo//*_bar")
      ["foo", "*_bar"]

  """
  def split(bin) when is_binary(bin) do
    for segment when segment != "" <- String.split(bin, "/"), do: segment
  end

  defp build_path_match([h | t], context, vars, acc) do
    handle_segment_match(segment_match(h, "", context), t, context, vars, acc)
  end

  defp build_path_match([], _context, vars, acc) do
    {vars |> Enum.uniq() |> Enum.reverse(), Enum.reverse(acc)}
  end

  # Handle each segment match. They can either be a
  # :literal ("foo"), an :identifier (":bar") or a :glob ("*path")

  defp handle_segment_match({:literal, literal}, t, context, vars, acc) do
    build_path_match(t, context, vars, [literal | acc])
  end

  defp handle_segment_match({:identifier, identifier, expr}, t, context, vars, acc) do
    build_path_match(t, context, [identifier | vars], [expr | acc])
  end

  defp handle_segment_match({:glob, _identifier, _expr}, t, _context, _vars, _acc) when t != [] do
    raise Helios.Router.InvalidSpecError, message: "cannot have a *glob followed by other segments"
  end

  defp handle_segment_match({:glob, identifier, expr}, _t, context, vars, [hs | ts]) do
    acc = [{:|, [], [hs, expr]} | ts]
    build_path_match([], context, [identifier | vars], acc)
  end

  defp handle_segment_match({:glob, identifier, expr}, _t, context, vars, _) do
    {vars, expr} = build_path_match([], context, [identifier | vars], [expr])
    {vars, hd(expr)}
  end

  # In a given segment, checks if there is a match.

  defp segment_match(":" <> argument, buffer, context) do
    identifier = binary_to_identifier(":", argument)

    expr =
      quote_if_buffer(identifier, buffer, context, fn var ->
        quote do: unquote(buffer) <> unquote(var)
      end)

    {:identifier, identifier, expr}
  end

  defp segment_match("*" <> argument, buffer, context) do
    underscore = {:_, [], context}
    identifier = binary_to_identifier("*", argument)

    expr =
      quote_if_buffer(identifier, buffer, context, fn var ->
        quote do: [unquote(buffer) <> unquote(underscore) | unquote(underscore)] = unquote(var)
      end)

    {:glob, identifier, expr}
  end

  defp segment_match(<<h, t::binary>>, buffer, context) do
    segment_match(t, buffer <> <<h>>, context)
  end

  defp segment_match(<<>>, buffer, _context) do
    {:literal, buffer}
  end

  defp quote_if_buffer(identifier, "", context, _fun) do
    {identifier, [], context}
  end

  defp quote_if_buffer(identifier, _buffer, context, fun) do
    fun.({identifier, [], context})
  end

  defp binary_to_identifier(prefix, <<letter, _::binary>> = binary)
       when letter in ?a..?z or letter == ?_ do
    if binary =~ ~r/^\w+$/ do
      String.to_atom(binary)
    else
      raise Helios.Router.InvalidSpecError,
        message: "#{prefix}identifier in routes must be made of letters, numbers and underscores"
    end
  end

  defp binary_to_identifier(prefix, _) do
    raise Helios.Router.InvalidSpecError,
      message: "#{prefix} in routes must be followed by lowercase letters or underscore"
  end
end
