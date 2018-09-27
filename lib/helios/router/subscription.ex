defmodule Helios.Router.Subscription do
  alias Helios.Router.Subscription
  @default_param_key "id"
  @path_prefix "/@"

  def __prefix__(), do: @path_prefix

  @doc """
  The `Phoenix.Router.Resource` struct. It stores:

    * `:path` - the path as string (not normalized) and it is allways equal to `"#{@path_prefix}"`
    * `:events` - the commands to which only this subscriber should repspond to
    * `:param` - the param to be used in routes (not normalized)
    * `:route` - the context for resource routes
    * `:subscriber` - the subscriber as an atom

  """
  defstruct [:path, :events, :param, :route, :subscriber, :singleton, :member, :collection]

  @type t :: %Subscription{
          path: String.t(),
          events: list(),
          param: String.t(),
          route: keyword,
          subscriber: atom(),
          singleton: boolean,
          member: keyword,
          collection: keyword
        }

  @doc """
  Builds a Subscription struct.
  """
  def build(path, subscriber, options) when is_atom(subscriber) and is_list(options) do
    path = Path.join(__prefix__(), path)
    alias = Keyword.get(options, :alias)
    param = Keyword.get(options, :param, @default_param_key)
    name = Keyword.get(options, :name, Helios.Naming.process_name(subscriber, "Subscription"))
    as = Keyword.get(options, :as, name)
    private = Keyword.get(options, :private, %{})
    assigns = Keyword.get(options, :assigns, %{})

    # TODO: this is not used currently but should work when set to true and
    #       distributed `IdentityServer` is imeplemented
    singleton = Keyword.get(options, :singleton, false)
    commands = extract_commands(options, singleton)

    route = [as: as, private: private, assigns: assigns]
    collection = [path: path, as: as, private: private, assigns: assigns]
    member_path = if singleton, do: path, else: Path.join(path, ":#{param}")
    member = [path: member_path, as: as, alias: alias, private: private, assigns: assigns]

    %Subscription{
      path: path,
      events: commands,
      param: param,
      route: route,
      subscriber: subscriber,
      singleton: singleton,
      member: member,
      collection: collection
    }
  end

  defp extract_commands(opts, _singleton?) do
    only = Keyword.get(opts, :to)
    except = Keyword.get(opts, :except)

    cond do
      only -> only
      except -> except
      true -> [:_]
    end
  end
end
