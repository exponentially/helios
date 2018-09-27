defmodule Helios.Naming do
  @moduledoc """
  Naming convention helpers.
  """

  @doc """
  Extracts the aggregate or process manager name from an alias.

  ## Examples

      iex> Helios.Naming.process_name(MyApp.User)
      "user"

      iex> Helios.Naming.process_name(MyApp.UserAggregate)
      "user"

  """
  @spec process_name(atom(), String.t) :: String.t
  def process_name(alias, suffix \\ "") do
    alias
    |> to_string()
    |> Module.split()
    |> List.last()
    |> unsuffix(suffix)
    |> underscore()
  end

  @doc """
  Removes the given suffix from the name if it exists.

  ## Examples

      iex> Helios.Naming.unsuffix("MyApp.User", "Aggregate")
      "MyApp.User"

      iex> Helios.Naming.unsuffix("MyApp.UserAggregate", "Aggregate")
      "MyApp.User"

  """
  @spec unsuffix(String.t, String.t) :: String.t
  def unsuffix(value, suffix) do
    string = to_string(value)
    suffix_size = byte_size(suffix)
    prefix_size = byte_size(string) - suffix_size
    case string do
      <<prefix::binary-size(prefix_size), ^suffix::binary>> -> prefix
      _ -> string
    end
  end

  @doc """
  Converts String to underscore case.

  ## Examples

      iex> Helios.Naming.underscore("MyApp")
      "my_app"

  In general, `underscore` can be thought of as the reverse of
  `camelize`, however, in some cases formatting may be lost:

      Helios.Naming.underscore "SAPExample"  #=> "sap_example"
      Helios.Naming.camelize   "sap_example" #=> "SapExample"

  """
  @spec underscore(String.t) :: String.t

  def underscore(value), do: Macro.underscore(value)

  defp to_lower_char(char) when char in ?A..?Z, do: char + 32
  defp to_lower_char(char), do: char

  @doc """
  Converts String to camel case.

  Takes an optional `:lower` option to return lowerCamelCase.

  ## Examples

      iex> Helios.Naming.camelize("my_app")
      "MyApp"

      iex> Helios.Naming.camelize("my_app", :lower)
      "myApp"

  In general, `camelize` can be thought of as the reverse of
  `underscore`, however, in some cases formatting may be lost:

      Helios.Naming.underscore "SAPExample"  #=> "sap_example"
      Helios.Naming.camelize   "sap_example" #=> "SapExample"

  """
  @spec camelize(String.t) :: String.t
  def camelize(value), do: Macro.camelize(value)

  @spec camelize(String.t, :lower) :: String.t
  def camelize("", :lower), do: ""
  def camelize(<<?_, t :: binary>>, :lower) do
    camelize(t, :lower)
  end
  def camelize(<<h, _t :: binary>> = value, :lower) do
    <<_first, rest :: binary>> = camelize(value)
    <<to_lower_char(h)>> <> rest
  end

  @doc """
  Converts an attribute/form field into its humanize version.

      iex> Helios.Naming.humanize(:username)
      "Username"
      iex> Helios.Naming.humanize(:created_at)
      "Created at"
      iex> Helios.Naming.humanize("user_id")
      "User"
  """
  @spec humanize(atom | String.t) :: String.t
  def humanize(atom) when is_atom(atom),
    do: humanize(Atom.to_string(atom))
  def humanize(bin) when is_binary(bin) do
    bin =
      if String.ends_with?(bin, "_id") do
        binary_part(bin, 0, byte_size(bin) - 3)
      else
        bin
      end

    bin |> String.replace("_", " ") |> String.capitalize
  end
end