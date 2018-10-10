defmodule Helios.Router.Aggregate do
  @moduledoc false
  alias Helios.Router.Aggregate
  @default_param_key "id"

  @doc """
  The `Phoenix.Router.Resource` struct. It stores:

    * `:path` - the path as string (not normalized)
    * `:commands` - the commands to which only this aggregate should repspond to
    * `:param` - the param to be used in routes (not normalized)
    * `:route` - the context for aggregate routes
    * `:aggregate` - the aggregate as an atom
    * `:singleton` - if only one single sinstance of aggregate should be ever created

  """
  defstruct [:path, :commands, :param, :route, :aggregate, :singleton, :member, :collection]

  @type t :: %Aggregate{
          path: String.t(),
          commands: list(),
          param: String.t(),
          route: keyword,
          aggregate: atom(),
          singleton: boolean,
          member: keyword,
          collection: keyword
        }

  @doc """
  Builds a aggregate struct.
  """
  def build(path, aggregate, options) when is_atom(aggregate) and is_list(options) do
    path = Helios.Router.Scope.validate_path(path)
    alias = Keyword.get(options, :alias)
    param = Keyword.get(options, :param, @default_param_key)
    name = Keyword.get(options, :name, Helios.Naming.process_name(aggregate, "Aggregate"))
    as = Keyword.get(options, :as, name)
    private = Keyword.get(options, :private, %{helios_plug_key: param})
    assigns = Keyword.get(options, :assigns, %{})

    # TODO: this is not used currently but should work when set to true and
    #       distributed `IdentityServer` is imeplemented
    singleton = Keyword.get(options, :singleton, false)
    commands = extract_commands(options, singleton)

    route = [as: as, private: private, assigns: assigns]
    collection = [path: path, as: as, private: private, assigns: assigns]
    member_path = if singleton, do: path, else: Path.join(path, ":#{param}")
    member = [path: member_path, as: as, alias: alias, private: private, assigns: assigns]

    %Aggregate{
      path: path,
      commands: commands,
      param: param,
      route: route,
      aggregate: aggregate,
      singleton: singleton,
      member: member,
      collection: collection
    }
  end

  defp extract_commands(opts, _singleton?) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except)

    cond do
      only -> only
      except -> except
      true -> [:_]
    end
  end
end
