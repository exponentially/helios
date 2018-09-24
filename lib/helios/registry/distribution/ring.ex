defmodule Helios.Registry.Distribution.Ring do
  @moduledoc """
  Default Helios.Registry distribution strategy.
  """
  @behaviour Helios.Registry.Distribution.Strategy

  def init(), do: HashRing.new()
  def add_node(ring, node), do: HashRing.add_node(ring, node)
  def add_node(ring, node, weight), do: HashRing.add_node(ring, node, weight)
  def add_nodes(ring, nodes), do: HashRing.add_nodes(ring, nodes)
  def remove_node(ring, node), do: HashRing.remove_node(ring, node)
  def key_to_node(ring, key), do: HashRing.key_to_node(ring, key)
end
