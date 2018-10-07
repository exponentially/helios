defprotocol Helios.Param do
  @moduledoc """
  A protocol that converts data structures into URI parameters.

  This protocol is used by URL helpers and other parts of the
  Helios stack. For example, if you call facade with:

      YourApp.Facade.User.create_user(1, %{"first_name" => "Foo", last_name => "Bar", "email" => "foo@example.com"})

  Helios knows how to extract the `:id` from first parameter thanks
  to this protocol. Since underneeth it will build path that will be used for routing

  By default, Helios implements this protocol for integers, binaries, atoms,
  and structs. For structs, a key `:id` is assumed, but you may provide a
  specific implementation.

  Nil values cannot be converted to param.

  ## Custom parameters

  In order to customize the parameter for any struct,
  one can simply implement this protocol.

  However, for convenience, this protocol can also be
  derivable. For example:

      defmodule CreateUser do
        @derive Helios.Param
        defstruct [:id, :username]
      end

  By default, the derived implementation will also use
  the `:id` key. In case the user does not contain an
  `:id` key, the key can be specified with an option:

      defmodule CreateUser do
        @derive {Helios.Param, key: :username}
        defstruct [:username]
      end

  will automatically use `:username` in URLs.

  """

  @fallback_to_any true

  @spec to_param(term) :: String.t
  def to_param(term)
end

defimpl Helios.Param, for: Integer do
  def to_param(int), do: Integer.to_string(int)
end

defimpl Helios.Param, for: BitString do
  def to_param(bin) when is_binary(bin), do: bin
end

defimpl Helios.Param, for: Atom do
  def to_param(nil) do
    raise ArgumentError, "cannot convert nil to param"
  end

  def to_param(atom) do
    Atom.to_string(atom)
  end
end

defimpl Helios.Param, for: Map do
  def to_param(map) do
    raise ArgumentError,
      "maps cannot be converted to_param. A struct was expected, got: #{inspect map}"
  end
end

defimpl Helios.Param, for: Any do
  defmacro __deriving__(module, struct, options) do
    key = Keyword.get(options, :key, :id)

    unless Map.has_key?(struct, key) do
      raise ArgumentError, "cannot derive Helios.Param for struct #{inspect module} " <>
                           "because it does not have key #{inspect key}. Please pass " <>
                           "the :key option when deriving"
    end

    quote do
      defimpl Helios.Param, for: unquote(module) do
        def to_param(%{unquote(key) => nil}) do
          raise ArgumentError, "cannot convert #{inspect unquote(module)} to param, " <>
                               "key #{inspect unquote(key)} contains a nil value"
        end

        def to_param(%{unquote(key) => key}) when is_integer(key), do: Integer.to_string(key)
        def to_param(%{unquote(key) => key}) when is_binary(key), do: key
        def to_param(%{unquote(key) => key}), do: Helios.Param.to_param(key)
      end
    end
  end

  def to_param(%{"id" => nil}) do
    raise ArgumentError, "cannot convert struct to param, key :id contains a nil value"
  end
  def to_param(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  def to_param(%{"id" => id}) when is_binary(id), do: id
  def to_param(%{"id" => id}), do: Helios.Param.to_param(id)

  def to_param(%{id: nil}) do
    raise ArgumentError, "cannot convert struct to param, key :id contains a nil value"
  end
  def to_param(%{id: id}) when is_integer(id), do: Integer.to_string(id)
  def to_param(%{id: id}) when is_binary(id), do: id
  def to_param(%{id: id}), do: Helios.Param.to_param(id)

  def to_param(map) when is_map(map) do
    raise ArgumentError,
      "structs expect an :id key when converting to_param or a custom implementation " <>
      "of the Helios.Param protocol (read Helios.Param docs for more information), " <>
      "got: #{inspect map}"
  end

  def to_param(data) do
    raise Protocol.UndefinedError, protocol: @protocol, value: data
  end
end
