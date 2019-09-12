defmodule Helios.Registry.Distribution.Strategy do
  @moduledoc """
  This module implements the interface for custom distribution strategies.
  The default strategy used by Helios.Registry is a consistent hash ring implemented
  via the `libring` library.

  Custom strategies are expected to return a datastructure or pid which will be
  passed along to any functions which need to manipulate the current distribution state.
  This can be either a plain datastructure (as is the case with the libring-based strategy),
  or a pid which your strategy module then uses to call a process in your own supervision tree.

  For efficiency reasons, it is highly recommended to use plain datastructures rather than a
  process for storing the distribution state, because it has the potential to become a bottleneck otherwise,
  however this is really up to the needs of your situation, just know that you can go either way.

  Strategy can be set in configuration, like so:

  ## Config example

      config :my_app, MyApp.Endpoint,
        registry:[
          distribution_strategy: {Helios.Registry.Distribution.Ring, :init, [
            nodes: [~r/my_node@/]
          ]}
        ]

  where `distibution_strategy` is requres {m, f, a} triplet that will be called using `Kernel.apply/3`
  during registry startup
  """

  @type reason :: String.t()
  @type strategy :: term
  @type weight :: pos_integer
  @type nodelist :: [node() | {node(), weight}]
  @type key :: term

  @type t :: strategy

  @doc """
  Adds a node to the state of the current distribution strategy.
  """
  @callback add_node(strategy, node) :: strategy | {:error, reason}

  @doc """
  Adds a node to the state of the current distribution strategy,
  and give it a specific weighting relative to other nodes.
  """
  @callback add_node(strategy, node, weight) :: strategy | {:error, reason}

  @doc """
  Adds a list of nodes to the state of the current distribution strategy.
  The node list can be composed of both node names (atoms) or tuples containing
  a node name and a weight for that node.
  """
  @callback add_nodes(strategy, nodelist) :: strategy | {:error, reason}

  @doc """
  Removes a node from the state of the current distribution strategy.
  """
  @callback remove_node(strategy, node) :: strategy | {:error, reason}

  @doc """
  Maps a key to a specific node via the current distribution strategy.
  """
  @callback key_to_node(strategy, key) :: node() | :undefined
end
