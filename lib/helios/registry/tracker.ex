defmodule Helios.Registry.Tracker do
  @moduledoc """
  This module implements the distributed tracker for process registrations and groups.
  It is implemented as a finite state machine, via `:gen_statem`.

  Each node Helios.Registry runs on will have a single instance of this process, and the trackers will
  replicate data between each other, and/or forward requests to remote trackers as necessary.
  """
  use GenStateMachine, callback_mode: :state_functions

  @sync_nodes_timeout 5_000
  @retry_interval 1_000
  @retry_max_attempts 10
  @default_anti_entropy_interval 5 * 60_000

  import Helios.Registry.Tracker.Entry
  use Helios.Logger

  require Helios.Registry
  alias Helios.Registry.Tracker.IntervalTreeClock, as: Clock
  alias Helios.Registry
  alias Helios.Registry.Distribution.Strategy

  defmodule Tracking do
    @moduledoc false
    @type t :: %__MODULE__{
            name: term(),
            meta: %{mfa: {m :: atom(), f :: function(), a :: list()}},
            from: {pid, tag :: term}
          }
    defstruct [:name, :meta, :from]
  end

  defmodule TrackerState do
    @moduledoc false
    @type t :: %__MODULE__{
            clock: nil | Helios.Registry.Tracker.IntervalTreeClock.t(),
            nodes: [],
            strategy: Strategy.t(),
            strategy_impl: module(),
            self: atom(),
            otp_app: atom(),
            endpoint: module(),
            config: [{atom(), list()}],
            sync_node: nil | atom(),
            sync_ref: nil | reference(),
            pending_sync_reqs: [pid()]
          }
    defstruct clock: nil,
              nodes: [],
              strategy: Helios.Registry.Distribution.Ring.init(),
              strategy_impl: Helios.Registry.Distribution.Ring,
              self: :nonode@nohost,
              otp_app: nil,
              endpoint: nil,
              config: [node_whitelist: [], node_blacklist: []],
              sync_node: nil,
              sync_ref: nil,
              pending_sync_reqs: []
  end

  def tracker_name(endpoint) do
    Module.concat(endpoint, EndpointTracker)
  end

  # Public API

  @doc """
  Authoritatively looks up the pid associated with a given name.
  """
  def whereis(endpoint, name) do
    GenStateMachine.call(tracker_name(endpoint), {:whereis, name}, :infinity)
  end

  @doc """
  Hand off all the processes running on the given worker to the remaining nodes in the cluster.
  This can be used to gracefully shut down a node.
  Note that if you don't shut down the node after the handoff a rebalance can lead to processes being scheduled on it again.
  In other words the handoff doesn't blacklist the node for further rebalances.
  """
  def handoff(endpoint, worker_name, state) do
    GenStateMachine.call(tracker_name(endpoint), {:handoff, worker_name, state}, :infinity)
  end

  @doc """
  Tracks a process (pid) with the given name.
  Tracking processes with this function will *not* restart the process when
  its parent node goes down, or shift the process to other nodes if the cluster
  topology changes. It is strictly for global name registration.
  """
  def track(endpoint, name, pid) when is_pid(pid),
    do: GenStateMachine.call(tracker_name(endpoint), {:track, name, pid, %{}}, :infinity)

  @doc """
  Tracks a process created via the provided module/function/args with the given name.
  The process will be distributed on the cluster based on the implementation of the configured distribution strategy.
  If the process' parent node goes down, it will be restarted on the new node which owns its keyspace.
  If the cluster topology changes, and the owner of its keyspace changes, it will be shifted to
  the new owner, after initiating the handoff process as described in the documentation.
  A track call will return an error tagged tuple, `{:error, :no_node_available}`, if there is no node available to start the process.
  Provide a timeout value to limit the track call duration. A value of `:infinity` can be used to block indefinitely.
  """
  def track(endpoint, name, m, f, a, timeout) when is_atom(m) and is_atom(f) and is_list(a),
    do: GenStateMachine.call(tracker_name(endpoint), {:track, name, %{mfa: {m, f, a}}}, timeout)

  @doc """
  Stops tracking the given process (pid).
  """
  def untrack(endpoint, pid) when is_pid(pid),
    do: GenStateMachine.call(tracker_name(endpoint), {:untrack, pid}, :infinity)

  @doc """
  Adds some metadata to the given process (pid). This is primarily used for tracking group membership.
  """
  def add_meta(endpoint, key, value, pid) when is_pid(pid),
    do: GenStateMachine.call(tracker_name(endpoint), {:add_meta, key, value, pid}, :infinity)

  @doc """
  Removes metadata from the given process (pid).
  """
  def remove_meta(endpoint, key, pid) when is_pid(pid),
    do: GenStateMachine.call(tracker_name(endpoint), {:remove_meta, key, pid}, :infinity)

  ## Process Internals / Internal API

  def child_spec(otp_app, endpoint) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [otp_app, endpoint]},
      type: :worker
    }
  end

  def start_link(otp_app, endpoint) do
    GenStateMachine.start_link(__MODULE__, [otp_app, endpoint], name: tracker_name(endpoint))
  end

  def init([otp_app, endpoint]) do
    # Trap exits
    config =
      endpoint.config(:registry, [])
      |> Keyword.put_new(:node_blacklist, [])
      |> Keyword.put_new(:node_whitelist, [])
      |> Keyword.put_new(
        :distribution_strategy,
        {Helios.Registry.Distribution.Ring, :init, []}
      )

    Process.flag(:trap_exit, true)
    # If this node is ignored, then make sure we ignore everyone else
    # to prevent accidentally interfering with the cluster
    config =
      if ignore_node?(config, Node.self()) do
        Keyword.put(config, :node_blacklist, [~r/^.+$/])
      else
        config
      end

    # Start monitoring nodes
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    info("Tracker started")
    nodelist = Enum.reject(Node.list(:connected), &ignore_node?(config, &1))

    {strategy_impl, init_fn, args} = config[:distribution_strategy]

    strategy =
      strategy_impl
      |> apply(init_fn, args)
      |> strategy_impl.add_node(Node.self())
      |> strategy_impl.add_nodes(nodelist)

    if Application.get_env(:helios, :trace) == true do
      _ = Task.start(fn -> :sys.trace(tracker_name(endpoint), true) end)
    end

    timeout = Keyword.get(config, :sync_nodes_timeout, @sync_nodes_timeout)
    Process.send_after(self(), :cluster_join, timeout)

    state = %TrackerState{
      nodes: nodelist,
      strategy: strategy,
      strategy_impl: strategy_impl,
      self: node(),
      otp_app: otp_app,
      endpoint: endpoint,
      config: config
    }

    {:ok, :cluster_wait, state}
  end

  def cluster_wait(:info, {:nodeup, node, _}, %TrackerState{} = state) do
    new_state =
      case nodeup(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  def cluster_wait(:info, {:nodedown, node, _}, %TrackerState{} = state) do
    new_state =
      case nodedown(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  def cluster_wait(:info, :cluster_join, %TrackerState{nodes: []} = state) do
    info("joining cluster..")
    info("no connected nodes, proceeding without sync")
    interval = Keyword.get(state.config, :anti_entropy_interval, @default_anti_entropy_interval)
    Process.send_after(self(), :anti_entropy, interval)
    {:next_state, :tracking, %{state | clock: Clock.seed()}}
  end

  def cluster_wait(:info, :cluster_join, %TrackerState{nodes: nodes} = state) do
    info("joining cluster..")
    info("found connected nodes: #{inspect(nodes)}")
    # Connect to a random node and sync registries,
    # start anti-entropy, and start loop with forked clock of
    # remote node
    sync_node = Enum.random(nodes)
    info("selected sync node: #{sync_node}")
    # Send sync request
    clock = Clock.seed()
    ref = Process.monitor({tracker_name(state.endpoint), sync_node})
    GenStateMachine.cast({tracker_name(state.endpoint), sync_node}, {:sync, self(), clock})
    {:next_state, :syncing, %{state | clock: clock, sync_node: sync_node, sync_ref: ref}}
  end

  def cluster_wait(:cast, {:sync, from, rclock}, %TrackerState{nodes: [from_node]} = state)
      when node(from) == from_node do
    info("joining cluster..")
    sync_node = node(from)
    info("syncing with #{sync_node}")
    ref = Process.monitor({tracker_name(state.endpoint), sync_node})

    GenStateMachine.cast(
      from,
      {:sync_recv, self(), rclock, get_registry_snapshot(state.endpoint)}
    )

    {:next_state, :awaiting_sync_ack,
     %{state | clock: rclock, sync_node: sync_node, sync_ref: ref}}
  end

  def cluster_wait(:cast, {:sync, from, _rclock}, %TrackerState{} = state) do
    if ignore_node?(state.config, node(from)) do
      GenStateMachine.cast(from, {:sync_err, :node_ignored})
      :keep_state_and_data
    else
      info("pending sync request from #{node(from)}")
      {:keep_state, %{state | pending_sync_reqs: [from | state.pending_sync_reqs]}}
    end
  end

  def cluster_wait(_event_type, _event_data, _state) do
    {:keep_state_and_data, :postpone}
  end

  def syncing(:info, {:nodeup, node, _}, %TrackerState{} = state) do
    new_state =
      case nodeup(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  def syncing(
        :info,
        {:DOWN, ref, _type, _pid, _info},
        %TrackerState{clock: clock, sync_ref: ref} = state
      ) do
    info("the remote tracker we're syncing with has crashed, selecting a new one")

    case state.nodes -- [state.sync_node] do
      [] ->
        info("no other available nodes, cancelling sync")
        new_state = %{state | sync_node: nil, sync_ref: nil}
        {:next_state, :tracking, new_state}

      new_nodes ->
        new_sync_node = Enum.random(new_nodes)
        info("selected sync node: #{new_sync_node}")
        # Send sync request
        ref = Process.monitor({tracker_name(state.endpoint), new_sync_node})

        GenStateMachine.cast(
          {tracker_name(state.endpoint), new_sync_node},
          {:sync, self(), clock}
        )

        new_state = %{state | sync_node: new_sync_node, sync_ref: ref}
        {:keep_state, new_state}
    end
  end

  def syncing(
        :info,
        {:nodedown, node, _},
        %TrackerState{strategy: strategy, clock: clock, nodes: nodes, sync_node: node} = state
      ) do
    info("the selected sync node #{node} went down, selecting new node")
    Process.demonitor(state.sync_ref, [:flush])

    case nodes -- [node] do
      [] ->
        # there are no other nodes to select, nothing to do
        info("no other available nodes, cancelling sync")

        new_state = %{
          state
          | nodes: [],
            strategy: state.strategy_impl.remove_node(strategy, node),
            sync_node: nil,
            sync_ref: nil
        }

        {:next_state, :tracking, new_state}

      new_nodes ->
        new_sync_node = Enum.random(new_nodes)
        info("selected sync node: #{new_sync_node}")
        # Send sync request
        ref = Process.monitor({tracker_name(state.endpoint), new_sync_node})

        GenStateMachine.cast(
          {tracker_name(state.endpoint), new_sync_node},
          {:sync, self(), clock}
        )

        new_state = %{
          state
          | nodes: new_nodes,
            strategy: state.strategy_impl.remove_node(strategy, node),
            sync_node: new_sync_node,
            sync_ref: ref
        }

        {:keep_state, new_state}
    end
  end

  def syncing(:info, {:nodedown, node, _}, %TrackerState{} = state) do
    new_state =
      case nodedown(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  # Successful anti-entropy sync
  def syncing(
        :cast,
        {:sync_recv, from, sync_clock, registry},
        %TrackerState{sync_node: sync_node} = state
      )
      when node(from) == sync_node do
    info("received registry from #{sync_node}, merging..")
    new_state = sync_registry(from, sync_clock, registry, state)
    # let remote node know we've got the registry
    GenStateMachine.cast(
      from,
      {:sync_ack, self(), new_state.clock, get_registry_snapshot(state.endpoint)}
    )

    info("local synchronization with #{sync_node} complete!")
    resolve_pending_sync_requests(new_state)
  end

  def syncing(:cast, {:sync_err, from}, %TrackerState{nodes: nodes, sync_node: sync_node} = state)
      when node(from) == sync_node do
    Process.demonitor(state.sync_ref, [:flush])

    if length(nodes) > 0 do
      # Something weird happened during sync, so try a different node,
      # with this implementation, we *could* end up selecting the same node
      # again, but that's fine as this is effectively a retry
      warn("a problem occurred during sync, choosing a new node to sync with")
      # we need to choose a different node to sync with and try again
      new_sync_node = Enum.random(nodes)
      ref = Process.monitor({tracker_name(state.endpoint), new_sync_node})

      GenStateMachine.cast(
        {tracker_name(state.endpoint), new_sync_node},
        {:sync, self(), state.clock}
      )

      {:keep_state, %{state | sync_node: new_sync_node, sync_ref: ref}}

      # Something went wrong during sync, but there are no other nodes to sync with,
      # not even the original sync node (which probably implies it shutdown or crashed),
      # so we're the sync node now
    else
      warn(
        "a problem occurred during sync, but no other available sync targets, becoming seed node"
      )

      {:next_state, :tracking, %{state | pending_sync_reqs: [], sync_node: nil, sync_ref: nil}}
    end
  end

  def syncing(:cast, {:sync, from, rclock}, %TrackerState{sync_node: sync_node} = state)
      when node(from) == sync_node do
    # We're trying to sync with another node while it is trying to sync with us, deterministically
    # choose the node which will coordinate the synchronization.
    local_node = Node.self()

    case Clock.compare(state.clock, rclock) do
      :lt ->
        # The local clock is dominated by the remote clock, so the remote node will begin the sync
        info("syncing from #{sync_node} based on tracker clock")
        :keep_state_and_data

      :gt ->
        # The local clock dominates the remote clock, so the local node will begin the sync
        info("syncing to #{sync_node} based on tracker clock")
        {lclock, rclock} = Clock.fork(state.clock)

        GenStateMachine.cast(
          from,
          {:sync_recv, self(), rclock, get_registry_snapshot(state.endpoint)}
        )

        {:next_state, :awaiting_sync_ack, %{state | clock: lclock}}

      result when result in [:eq, :concurrent] and sync_node > local_node ->
        # The remote node will begin the sync
        info("syncing from #{sync_node} based on node precedence")
        :keep_state_and_data

      result when result in [:eq, :concurrent] ->
        # The local node begins the sync
        info("syncing to #{sync_node} based on node precedence")
        {lclock, rclock} = Clock.fork(state.clock)

        GenStateMachine.cast(
          from,
          {:sync_recv, self(), rclock, get_registry_snapshot(state.endpoint)}
        )

        {:next_state, :awaiting_sync_ack, %{state | clock: lclock}}
    end
  end

  def syncing(:cast, {:sync, from, _rclock}, %TrackerState{} = state) do
    if ignore_node?(state.config, node(from)) do
      GenStateMachine.cast(from, {:sync_err, :node_ignored})
      :keep_state_and_data
    else
      info("pending sync request from #{node(from)}")
      new_pending_reqs = Enum.uniq([from | state.pending_sync_reqs])
      {:keep_state, %{state | pending_sync_reqs: new_pending_reqs}}
    end
  end

  def syncing(_event_type, _event_data, _state) do
    {:keep_state_and_data, :postpone}
  end

  defp sync_registry(from, sync_clock, registry, %TrackerState{endpoint: endpoint} = state)
       when is_pid(from) do
    sync_node = node(from)
    # map over the registry and check that all local entries are correct
    Enum.each(registry, fn entry(name: rname, pid: rpid, meta: rmeta, clock: rclock) = rreg ->
      case Registry.get_by_name(endpoint, rname) do
        :undefined ->
          # missing local registration
          debug("local tracker is missing #{inspect(rname)}, adding to registry")
          ref = Process.monitor(rpid)
          lclock = Clock.join(sync_clock, rclock)

          Registry.new!(
            endpoint,
            entry(name: rname, pid: rpid, ref: ref, meta: rmeta, clock: lclock)
          )

        entry(pid: ^rpid, meta: lmeta, clock: lclock) ->
          case Clock.compare(lclock, rclock) do
            :lt ->
              # the remote clock dominates, take remote data
              lclock = Clock.join(lclock, rclock)
              Registry.update(endpoint, rname, meta: rmeta, clock: lclock)

              debug(
                "sync metadata for #{inspect(rpid)} (#{inspect(rmeta)}) is causally dominated by remote, updated registry..."
              )

            :gt ->
              # the local clock dominates, keep local data
              debug(
                "sync metadata for #{inspect(rpid)} (#{inspect(rmeta)}) is causally dominated by local, ignoring..."
              )

              :ok

            :eq ->
              # the clocks are the same, no-op
              debug(
                "sync metadata for #{inspect(rpid)} (#{inspect(rmeta)}) has equal clocks, ignoring..."
              )

              :ok

            :concurrent ->
              warn("local and remote metadata for #{inspect(rname)} was concurrently modified")

              new_meta = Map.merge(lmeta, rmeta)

              # we're going to join and bump our local clock though and re-broadcast the update to ensure we converge
              lclock = Clock.join(lclock, rclock)
              lclock = Clock.event(lclock)
              Registry.update(endpoint, rname, meta: new_meta, clock: lclock)
              broadcast_event(endpoint, state.nodes, lclock, {:update_meta, new_meta, rpid})
          end

        entry(pid: lpid, clock: lclock) = lreg ->
          # there are two different processes for the same name, we need to resolve
          case Clock.compare(lclock, rclock) do
            :lt ->
              # the remote registration dominates
              resolve_incorrect_local_reg(sync_node, lreg, rreg, state)

            :gt ->
              # local registration dominates
              debug("remote view of #{inspect(rname)} is outdated, resolving..")
              resolve_incorrect_remote_reg(sync_node, lreg, rreg, state)

            _ ->
              # the entry clocks conflict, determine which one is correct based on
              # current topology and resolve the conflict
              rpid_node = node(rpid)
              lpid_node = node(lpid)

              case state.strategy_impl.key_to_node(state.strategy, rname) do
                ^rpid_node when lpid_node != rpid_node ->
                  debug(
                    "remote and local view of #{inspect(rname)} conflict, but remote is correct, resolving.."
                  )

                  resolve_incorrect_local_reg(sync_node, lreg, rreg, state)

                ^lpid_node when lpid_node != rpid_node ->
                  debug(
                    "remote and local view of #{inspect(rname)} conflict, but local is correct, resolving.."
                  )

                  resolve_incorrect_remote_reg(sync_node, lreg, rreg, state)

                _ ->
                  cond do
                    lpid_node == rpid_node and lpid > rpid ->
                      debug(
                        "remote and local view of #{inspect(rname)} conflict, but local is more recent, resolving.."
                      )

                      resolve_incorrect_remote_reg(sync_node, lreg, rreg, state)

                    lpid_node == rpid_node and lpid < rpid ->
                      debug(
                        "remote and local view of #{inspect(rname)} conflict, but remote is more recent, resolving.."
                      )

                      resolve_incorrect_local_reg(sync_node, lreg, rreg, state)

                    :else ->
                      # name should be on another node, so neither registration is correct
                      debug(
                        "remote and local view of #{inspect(rname)} are both outdated, resolving.."
                      )

                      resolve_incorrect_local_reg(sync_node, lreg, rreg, state)
                  end
              end
          end
      end
    end)

    %{state | clock: sync_clock}
  end

  defp resolve_pending_sync_requests(%TrackerState{pending_sync_reqs: []} = state) do
    info("pending sync requests cleared")

    case state.sync_ref do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end

    {:next_state, :tracking, %{state | sync_node: nil, sync_ref: nil}}
  end

  defp resolve_pending_sync_requests(%TrackerState{pending_sync_reqs: [pid | pending]} = state) do
    pending_node = node(pid)
    # Remove monitoring of the previous sync node
    case state.sync_ref do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end

    if Enum.member?(state.nodes, pending_node) do
      info("clearing pending sync request for #{pending_node}")
      {lclock, rclock} = Clock.fork(state.clock)
      ref = Process.monitor(pid)

      GenStateMachine.cast(
        pid,
        {:sync_recv, self(), rclock, get_registry_snapshot(state.endpoint)}
      )

      new_state = %{
        state
        | sync_node: node(pid),
          sync_ref: ref,
          pending_sync_reqs: pending,
          clock: lclock
      }

      {:next_state, :awaiting_sync_ack, new_state}
    else
      resolve_pending_sync_requests(%{
        state
        | sync_node: nil,
          sync_ref: nil,
          pending_sync_reqs: pending
      })
    end
  end

  def awaiting_sync_ack(
        :cast,
        {:sync_ack, from, sync_clock, registry},
        %TrackerState{sync_node: sync_node} = state
      )
      when sync_node == node(from) do
    info("received sync acknowledgement from #{node(from)}, syncing with remote registry")

    new_state = sync_registry(from, sync_clock, registry, state)
    info("local synchronization with #{node(from)} complete!")
    resolve_pending_sync_requests(new_state)
  end

  def awaiting_sync_ack(
        :info,
        {:DOWN, ref, _type, _pid, _info},
        %TrackerState{sync_ref: ref} = state
      ) do
    warn("wait for acknowledgement from #{state.sync_node} cancelled, tracker down")
    resolve_pending_sync_requests(%{state | sync_node: nil, sync_ref: nil})
  end

  def awaiting_sync_ack(:info, {:nodeup, node, _}, %TrackerState{} = state) do
    new_state =
      case nodeup(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  def awaiting_sync_ack(:info, {:nodedown, node, _}, %TrackerState{sync_node: node} = state) do
    new_state =
      case nodedown(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    Process.demonitor(state.sync_ref, [:flush])
    resolve_pending_sync_requests(%{new_state | sync_node: nil, sync_ref: nil})
  end

  def awaiting_sync_ack(:info, {:nodedown, node, _}, %TrackerState{} = state) do
    new_state =
      case nodedown(state, node) do
        {:ok, new_state} -> new_state
        {:ok, new_state, _next_state} -> new_state
      end

    {:keep_state, new_state}
  end

  def awaiting_sync_ack(_event_type, _event_data, _state) do
    {:keep_state_and_data, :postpone}
  end

  def tracking(:info, {:EXIT, _child, _reason}, _state) do
    # A child process started by this tracker has crashed
    :keep_state_and_data
  end

  def tracking(:info, {:nodeup, node, _}, %TrackerState{nodes: []} = state) do
    if ignore_node?(state.config, node) do
      :keep_state_and_data
    else
      # This case occurs when the tracker comes up without being connected to a cluster
      # and a cluster forms after some period of time. In this case, we need to treat this
      # like a cluster_wait -> cluster_join scenario, so that we sync with cluster and ensure
      # any registrations on the remote node are in the local registry and vice versa
      new_state =
        case nodeup(state, node) do
          {:ok, new_state} -> new_state
          {:ok, new_state, _next_state} -> new_state
        end

      cluster_wait(:info, :cluster_join, new_state)
    end
  end

  def tracking(:info, {:nodeup, node, _}, state) do
    state
    |> nodeup(node)
    |> handle_node_status()
  end

  def tracking(:info, {:nodedown, node, _}, state) do
    state
    |> nodedown(node)
    |> handle_node_status()
  end

  def tracking(:info, {:ensure_swarm_started_on_remote_node, node, attempts}, state) do
    state
    |> ensure_swarm_started_on_remote_node(node, attempts)
    |> handle_node_status()
  end

  def tracking(:info, :anti_entropy, state) do
    anti_entropy(state)
  end

  # A change event received from another replica/node
  def tracking(:cast, {:event, from, rclock, event}, state) do
    handle_replica_event(from, event, rclock, state)
  end

  # Received a handoff request from a node
  def tracking(:cast, {:handoff, from, {name, meta, handoff_state, rclock}}, state) do
    handle_handoff(from, {name, meta, handoff_state, rclock}, state)
  end

  # A remote registration failed due to nodedown during the call
  def tracking(:cast, {:retry, from, {:track, name, m, f, a}}, state) do
    handle_retry(from, {:track, name, %{mfa: {m, f, a}}}, state)
  end

  # A change event received locally
  def tracking({:call, from}, msg, state) do
    handle_call(msg, from, state)
  end

  def tracking(:cast, msg, state) do
    handle_cast(msg, state)
  end

  # A tracked process has gone down
  def tracking(:info, {:DOWN, ref, _type, pid, info}, state) do
    handle_monitor(ref, pid, info, state)
  end

  def tracking(event_type, event_data, state) do
    handle_event(event_type, event_data, state)
  end

  # This state helps us ensure that nodes proactively keep themselves synced
  # after joining the cluster and initial syncrhonization. This way if replication
  # events fail for some reason, we can control the drift in registry state
  def anti_entropy(%TrackerState{nodes: [], endpoint: endpoint} = _) do
    interval = endpoint.config(:anti_entropy_interval, @default_anti_entropy_interval)
    Process.send_after(self(), :anti_entropy, interval)
    :keep_state_and_data
  end

  def anti_entropy(%TrackerState{nodes: nodes, endpoint: endpoint} = state) do
    sync_node = Enum.random(nodes)
    info("syncing with #{sync_node}")
    ref = Process.monitor({tracker_name(endpoint), sync_node})
    GenStateMachine.cast({tracker_name(endpoint), sync_node}, {:sync, self(), state.clock})
    new_state = %{state | sync_node: sync_node, sync_ref: ref}
    interval = endpoint.config(:anti_entropy_interval, @default_anti_entropy_interval)
    Process.send_after(self(), :anti_entropy, interval)
    {:next_state, :syncing, new_state}
  end

  # This message is sent as a broadcast message for replication
  def handle_event(:info, {:event, from, rclock, event}, state) do
    handle_replica_event(from, event, rclock, state)
  end

  # If we receive cluster_join outside of cluster_wait it's because
  # we implicitly joined the cluster due to a sync event, we know if
  # we receive such an event the cluster is already formed due to how
  # Erlang distribution works (it's a mesh)
  def handle_event(:info, :cluster_join, _state) do
    :keep_state_and_data
  end

  def handle_event({:call, from}, msg, state) do
    handle_call(msg, from, state)
  end

  def handle_event(:cast, msg, state) do
    handle_cast(msg, state)
  end

  # Default event handler
  def handle_event(event_type, event_data, _state) do
    debug("unexpected event: #{inspect({event_type, event_data})}")
    :keep_state_and_data
  end

  def code_change(_oldvsn, state, data, _extra) do
    {:ok, state, data}
  end

  defp handle_node_status({:ok, new_state}), do: {:keep_state, new_state}

  defp handle_node_status({:ok, new_state, {:topology_change, change_info}}) do
    handle_topology_change(change_info, new_state)
  end

  # This is the callback for when a process is being handed off from a remote node to this node.
  defp handle_handoff(
         from,
         {name, meta, handoff_state, rclock},
         %TrackerState{clock: clock, endpoint: endpoint} = state
       ) do
    try do
      # If a network split is being healed, we almost certainly will have a
      # local registration already for this name (since it was present on this side of the split)
      # If not, we'll restart it, but if so, we'll send the handoff state to the old process and
      # let it determine how to resolve the conflict
      current_node = Node.self()

      case Registry.get_by_name(endpoint, name) do
        :undefined ->
          {{m, f, a}, _other_meta} = Map.pop(meta, :mfa)
          {:ok, pid} = apply(m, f, a)
          GenServer.cast(pid, {:helios, :end_handoff, handoff_state})
          ref = Process.monitor(pid)
          lclock = Clock.join(clock, rclock)

          Registry.new!(
            endpoint,
            entry(name: name, pid: pid, ref: ref, meta: meta, clock: lclock)
          )

          broadcast_event(endpoint, state.nodes, lclock, {:track, name, pid, meta})
          {:keep_state, state}

        entry(pid: pid) when node(pid) == current_node ->
          GenServer.cast(pid, {:helios, :resolve_conflict, handoff_state})
          lclock = Clock.join(clock, rclock)
          broadcast_event(endpoint, state.nodes, lclock, {:track, name, pid, meta})
          {:keep_state, state}

        entry(pid: pid, ref: ref) = obj when node(pid) == node(from) ->
          # We have received the handoff before we've received the untrack event, but because
          # the handoff is coming from the node where the registration existed, we can safely
          # remove the registration now, and proceed with the handoff
          Process.demonitor(ref, [:flush])
          Registry.remove(endpoint, obj)
          # Re-enter this callback to take advantage of the first clause
          handle_handoff(from, {name, meta, handoff_state, rclock}, state)
      end
    catch
      kind, err ->
        error(Exception.format(kind, err, System.stacktrace()))
        :keep_state_and_data
    end
  end

  # This is the callback for when a nodeup/down event occurs after the tracker has entered
  # the main receive loop. Topology changes are handled a bit differently during startup.
  defp handle_topology_change({type, remote_node}, %TrackerState{endpoint: endpoint} = state) do
    debug("topology change (#{type} for #{remote_node})")
    current_node = state.self

    new_clock =
      Registry.reduce(endpoint, state.clock, fn
        entry(name: name, pid: pid, meta: %{mfa: _mfa} = meta) = obj, lclock
        when node(pid) == current_node ->
          case state.strategy_impl.key_to_node(state.strategy, name) do
            :undefined ->
              # No node available to host process, it must be stopped
              debug("#{inspect(pid)} must be stopped as no node is available to host it")

              {:ok, new_state} = remove_registration(obj, %{state | clock: lclock})
              send(pid, {:helios, :die})
              new_state.clock

            ^current_node ->
              # This process is correct
              lclock

            other_node ->
              debug("#{inspect(pid)} belongs on #{other_node}")
              # This process needs to be moved to the new node
              try do
                case GenServer.call(pid, {:helios, :begin_handoff}) do
                  :ignore ->
                    debug("#{inspect(name)} has requested to be ignored")
                    lclock

                  {:resume, handoff_state} ->
                    debug("#{inspect(name)} has requested to be resumed")
                    {:ok, state} = remove_registration(obj, %{state | clock: lclock})
                    send(pid, {:helios, :die})
                    debug("sending handoff for #{inspect(name)} to #{other_node}")

                    GenStateMachine.cast(
                      {tracker_name(endpoint), other_node},
                      {:handoff, self(), {name, meta, handoff_state, Clock.peek(state.clock)}}
                    )

                    state.clock

                  :restart ->
                    debug("#{inspect(name)} has requested to be restarted")
                    {:ok, new_state} = remove_registration(obj, %{state | clock: lclock})
                    send(pid, {:helios, :die})

                    case do_track(%Tracking{name: name, meta: meta}, new_state) do
                      :keep_state_and_data -> new_state.clock
                      {:keep_state, new_state} -> new_state.clock
                    end
                end
              catch
                _, err ->
                  warn("handoff failed for #{inspect(name)}: #{inspect(err)}")
                  lclock
              end
          end

        entry(name: name, pid: pid, meta: %{mfa: _mfa} = meta) = obj, lclock when is_map(meta) ->
          if Enum.member?(state.nodes, node(pid)) do
            # the parent node is still up
            lclock
          else
            # pid is dead, we're going to restart it
            case state.strategy_impl.key_to_node(state.strategy, name) do
              :undefined ->
                # No node available to restart process on, so remove registration
                warn("no node available to restart #{inspect(name)}")
                {:ok, new_state} = remove_registration(obj, %{state | clock: lclock})
                new_state.clock

              ^current_node ->
                debug("restarting #{inspect(name)} on #{current_node}")
                {:ok, new_state} = remove_registration(obj, %{state | clock: lclock})

                case do_track(%Tracking{name: name, meta: meta}, new_state) do
                  :keep_state_and_data -> new_state.clock
                  {:keep_state, new_state} -> new_state.clock
                end

              _other_node ->
                # other_node will tell us to unregister/register the restarted pid
                lclock
            end
          end

        entry(name: name, pid: pid) = obj, lclock ->
          pid_node = node(pid)

          if pid_node == current_node or Enum.member?(state.nodes, pid_node) do
            # the parent node is still up
            lclock
          else
            # the parent node is down, but we cannot restart this pid, so unregister it
            debug("removing registration for #{inspect(name)}, #{pid_node} is down")

            {:ok, new_state} = remove_registration(obj, %{state | clock: lclock})
            new_state.clock
          end
      end)

    info("topology change complete")
    {:keep_state, %{state | clock: new_clock}}
  end

  # This is the callback for tracker events which are being replicated from other nodes in the cluster
  defp handle_replica_event(_from, {:track, name, pid, meta}, rclock, %TrackerState{
         clock: clock,
         endpoint: endpoint
       }) do
    debug("replicating registration for #{inspect(name)} (#{inspect(pid)}) locally")

    case Registry.get_by_name(endpoint, name) do
      entry(name: ^name, pid: ^pid, meta: ^meta) ->
        # We're already up to date
        :keep_state_and_data

      entry(name: ^name, pid: ^pid, clock: lclock) ->
        # We don't have the same view of the metadata
        cond do
          Clock.leq(lclock, rclock) ->
            # The remote version is dominant
            lclock = Clock.join(lclock, rclock)
            Registry.update(endpoint, name, meta: meta, clock: lclock)
            :keep_state_and_data

          Clock.leq(rclock, lclock) ->
            # The local version is dominant
            :keep_state_and_data

          :else ->
            warn(
              "received track event for #{inspect(name)}, but local clock conflicts with remote clock, event unhandled"
            )

            :keep_state_and_data
        end

      entry(name: ^name, pid: other_pid, ref: ref, clock: lclock) = obj ->
        # we have conflicting views of this name, compare clocks and fix it
        current_node = Node.self()

        cond do
          Clock.leq(lclock, rclock) and node(other_pid) == current_node ->
            # The remote version is dominant, kill the local pid and remove the registration
            Process.demonitor(ref, [:flush])
            Process.exit(other_pid, :kill)
            Registry.remove(endpoint, obj)
            new_ref = Process.monitor(pid)
            lclock = Clock.join(lclock, rclock)

            Registry.new!(
              endpoint,
              entry(name: name, pid: pid, ref: new_ref, meta: meta, clock: lclock)
            )

            :keep_state_and_data

          Clock.leq(rclock, lclock) ->
            # The local version is dominant, so ignore this event
            :keep_state_and_data

          :else ->
            # The clocks are conflicted, warn, and ignore this event
            warn(
              "received track event for #{inspect(name)}, mismatched pids, local clock conflicts with remote clock, event unhandled"
            )

            :keep_state_and_data
        end

      :undefined ->
        ref = Process.monitor(pid)
        lclock = Clock.join(clock, rclock)
        Registry.new!(endpoint, entry(name: name, pid: pid, ref: ref, meta: meta, clock: lclock))
        :keep_state_and_data
    end
  end

  defp handle_replica_event(_from, {:untrack, pid}, rclock, %{endpoint: endpoint} = _state) do
    debug("replica event: untrack #{inspect(pid)}")

    case Registry.get_by_pid(endpoint, pid) do
      :undefined ->
        :keep_state_and_data

      entries when is_list(entries) ->
        Enum.each(entries, fn entry(ref: ref, clock: lclock) = obj ->
          cond do
            Clock.leq(lclock, rclock) ->
              # registration came before unregister, so remove the registration
              Process.demonitor(ref, [:flush])
              Registry.remove(endpoint, obj)

            Clock.leq(rclock, lclock) ->
              # registration is newer than de-registration, ignore msg
              debug("untrack is causally dominated by track for #{inspect(pid)}, ignoring..")

            :else ->
              debug("untrack is causally conflicted with track for #{inspect(pid)}, ignoring..")
          end
        end)

        :keep_state_and_data
    end
  end

  defp handle_replica_event(
         _from,
         {:update_meta, new_meta, pid},
         rclock,
         %{endpoint: endpoint} = state
       ) do
    debug("replica event: update_meta #{inspect(new_meta)} for #{inspect(pid)}")

    case Registry.get_by_pid(endpoint, pid) do
      :undefined ->
        :keep_state_and_data

      entries when is_list(entries) ->
        Enum.each(entries, fn entry(name: name, meta: old_meta, clock: lclock) ->
          cond do
            Clock.leq(lclock, rclock) ->
              lclock = Clock.join(lclock, rclock)
              Registry.update(endpoint, name, meta: new_meta, clock: lclock)

              debug(
                "request to update meta from #{inspect(pid)} (#{inspect(new_meta)}) is causally dominated by remote, updated registry..."
              )

            Clock.leq(rclock, lclock) ->
              # ignore the request, as the local clock dominates the remote
              debug(
                "request to update meta from #{inspect(pid)} (#{inspect(new_meta)}) is causally dominated by local, ignoring.."
              )

            :else ->
              new_meta = Map.merge(old_meta, new_meta)

              # we're going to join and bump our local clock though and re-broadcast the update to ensure we converge
              debug(
                "conflicting meta for #{inspect(name)}, updating and notifying other nodes, old meta: #{
                  inspect(old_meta)
                }, new meta: #{inspect(new_meta)}"
              )

              lclock = Clock.join(lclock, rclock)
              lclock = Clock.event(lclock)
              Registry.update(endpoint, name, meta: new_meta, clock: lclock)
              broadcast_event(endpoint, state.nodes, lclock, {:update_meta, new_meta, pid})
          end
        end)

        :keep_state_and_data
    end
  end

  defp handle_replica_event(_from, event, _clock, _state) do
    warn("received unrecognized replica event: #{inspect(event)}")
    :keep_state_and_data
  end

  # This is the handler for local operations on the tracker which require a response.
  defp handle_call({:whereis, name}, from, %TrackerState{
         strategy: strategy,
         strategy_impl: strategy_impl,
         endpoint: endpoint
       }) do
    current_node = Node.self()

    case strategy_impl.key_to_node(strategy, name) do
      :undefined ->
        GenStateMachine.reply(from, :undefined)

      ^current_node ->
        case Registry.get_by_name(endpoint, name) do
          :undefined ->
            GenStateMachine.reply(from, :undefined)

          entry(pid: pid) ->
            GenStateMachine.reply(from, pid)
        end

      other_node ->
        _ =
          Task.Supervisor.start_child(Helios.Registry.TaskSupervisor, fn ->
            case :rpc.call(other_node, Helios.Registry, :get_by_name, [name], :infinity) do
              :undefined ->
                GenStateMachine.reply(from, :undefined)

              entry(pid: pid) ->
                GenStateMachine.reply(from, pid)

              {:badrpc, reason} ->
                warn(
                  "failed to execute remote get_by_name on #{inspect(other_node)}: #{
                    inspect(reason)
                  }"
                )

                GenStateMachine.reply(from, :undefined)
            end
          end)
    end

    :keep_state_and_data
  end

  defp handle_call({:track, name, pid, meta}, from, %TrackerState{} = state) do
    debug("registering #{inspect(pid)} as #{inspect(name)}, with metadata #{inspect(meta)}")

    add_registration({name, pid, meta}, from, state)
  end

  defp handle_call({:track, name, meta}, from, state) do
    current_node = Node.self()
    {{m, f, a}, _other_meta} = Map.pop(meta, :mfa)

    case from do
      {from_pid, _} when node(from_pid) != current_node ->
        debug(
          "#{inspect(node(from_pid))} is registering #{inspect(name)} as process started by #{m}.#{
            f
          }/#{length(a)} with args #{inspect(a)}"
        )

      _ ->
        debug(
          "registering #{inspect(name)} as process started by #{m}.#{f}/#{length(a)} with args #{
            inspect(a)
          }"
        )
    end

    do_track(%Tracking{name: name, meta: meta, from: from}, state)
  end

  defp handle_call({:untrack, pid}, from, %TrackerState{} = state) do
    debug("untrack #{inspect(pid)}")
    {:ok, new_state} = remove_registration_by_pid(pid, state)
    GenStateMachine.reply(from, :ok)
    {:keep_state, new_state}
  end

  defp handle_call({:add_meta, key, value, pid}, from, %TrackerState{} = state) do
    debug("add_meta #{inspect({key, value})} to #{inspect(pid)}")
    {:ok, new_state} = add_meta_by_pid({key, value}, pid, state)
    GenStateMachine.reply(from, :ok)
    {:keep_state, new_state}
  end

  defp handle_call({:remove_meta, key, pid}, from, %TrackerState{} = state) do
    debug("remote_meta #{inspect(key)} for #{inspect(pid)}")
    {:ok, new_state} = remove_meta_by_pid(key, pid, state)
    GenStateMachine.reply(from, :ok)
    {:keep_state, new_state}
  end

  defp handle_call(
         {:handoff, worker_name, handoff_state},
         from,
         %{strategy_impl: strategy_impl} = state
       ) do
    state.endpoint
    |> Registry.get_by_name(worker_name)
    |> case do
      :undefined ->
        # Worker was already removed from registry -> do nothing
        debug("The node #{worker_name} was not found in the registry")

      entry(name: name, pid: pid, meta: %{mfa: _mfa} = meta) = obj ->
        with removed_node <- strategy_impl.remove_node(state.strategy, state.self),
             {:error, {:invalid_ring, :no_nodes}} <- strategy_impl.key_to_node(removed_node, name) do
          debug("Cannot handoff #{inspect(name)} because there is no other node left")
        else
          other_node ->
            debug("#{inspect(name)} has requested to be terminated and resumed on another node")

            {:ok, state} = remove_registration(obj, %{state | clock: state.clock})
            send(pid, {:helios, :die})
            debug("sending handoff for #{inspect(name)} to #{other_node}")

            GenStateMachine.cast(
              {tracker_name(state.endpoint), other_node},
              {:handoff, self(), {name, meta, handoff_state, Clock.peek(state.clock)}}
            )
        end
    end

    GenStateMachine.reply(from, :finished)
    :keep_state_and_data
  end

  defp handle_call(msg, _from, _state) do
    warn("unrecognized call: #{inspect(msg)}")
    :keep_state_and_data
  end

  # This is the handler for local operations on the tracker which are asynchronous
  defp handle_cast({:sync, from, _rclock}, %TrackerState{clock: clock} = state) do
    if ignore_node?(state.config, node(from)) do
      GenStateMachine.cast(from, {:sync_err, :node_ignored})
      :keep_state_and_data
    else
      debug("received sync request from #{node(from)}")
      {lclock, rclock} = Clock.fork(clock)
      sync_node = node(from)
      ref = Process.monitor(from)

      GenStateMachine.cast(
        from,
        {:sync_recv, self(), rclock, get_registry_snapshot(state.endpoint)}
      )

      {:next_state, :awaiting_sync_ack,
       %{state | clock: lclock, sync_node: sync_node, sync_ref: ref}}
    end
  end

  defp handle_cast(msg, _state) do
    warn("unrecognized cast: #{inspect(msg)}")
    :keep_state_and_data
  end

  # This is only ever called if a registration needs to be sent to a remote node
  # and that node went down in the middle of the call to its Helios.Registry process.
  # We need to process the nodeup/down events by re-entering the receive loop first,
  # so we send ourselves a message to retry. This is the handler for that message.
  defp handle_retry(from, {:track, name, meta}, state) do
    handle_call({:track, name, meta}, from, state)
  end

  defp handle_retry(_from, _event, _state) do
    :keep_state_and_data
  end

  # Called when a pid dies, and the monitor is triggered
  defp handle_monitor(ref, pid, :noconnection, %TrackerState{endpoint: endpoint} = state) do
    # lost connection to the node this pid is running on, check if we should restart it
    case Registry.get_by_ref(endpoint, ref) do
      :undefined ->
        debug(
          "lost connection to #{inspect(pid)}, but no registration could be found, ignoring.."
        )

        :keep_state_and_data

      entry(name: name, pid: ^pid, meta: %{mfa: _mfa}) ->
        debug(
          "lost connection to #{inspect(name)} (#{inspect(pid)}) on #{node(pid)}, node is down"
        )

        state
        |> nodedown(node(pid))
        |> handle_node_status()

      entry(pid: ^pid) = obj ->
        debug("lost connection to #{inspect(pid)}, but not restartable, removing registration..")

        {:ok, new_state} = remove_registration(obj, state)
        {:keep_state, new_state}
    end
  end

  defp handle_monitor(ref, pid, reason, %TrackerState{endpoint: endpoint} = state) do
    case Registry.get_by_ref(endpoint, ref) do
      :undefined ->
        debug(
          "#{inspect(pid)} is down: #{inspect(reason)}, but no registration found, ignoring.."
        )

        :keep_state_and_data

      entry(name: name, pid: ^pid) = obj ->
        debug("#{inspect(name)} is down: #{inspect(reason)}")
        {:ok, new_state} = remove_registration(obj, state)
        {:keep_state, new_state}
    end
  end

  # Attempt to start a named process on its destination node
  defp do_track(
         %Tracking{name: name, meta: meta, from: from},
         %TrackerState{strategy: strategy, endpoint: endpoint} = state
       ) do
    current_node = Node.self()
    {{m, f, a}, _other_meta} = Map.pop(meta, :mfa)

    case state.strategy_impl.key_to_node(strategy, name) do
      :undefined ->
        warn("no node available to start #{inspect(name)} process")
        reply(from, {:error, :no_node_available})
        :keep_state_and_data

      ^current_node ->
        case Registry.get_by_name(endpoint, name) do
          :undefined ->
            debug("starting #{inspect(name)} on #{current_node}")

            try do
              case apply(m, f, a) do
                {:ok, pid} ->
                  debug("started #{inspect(name)} on #{current_node}")
                  add_registration({name, pid, meta}, from, state)

                err ->
                  warn("failed to start #{inspect(name)} on #{current_node}: #{inspect(err)}")

                  reply(from, {:error, {:invalid_return, err}})
                  :keep_state_and_data
              end
            catch
              kind, reason ->
                warn(Exception.format(kind, reason, System.stacktrace()))
                reply(from, {:error, reason})
                :keep_state_and_data
            end

          entry(pid: pid) ->
            debug("found #{inspect(name)} already registered on #{node(pid)}")
            reply(from, {:error, {:already_registered, pid}})
            :keep_state_and_data
        end

      remote_node ->
        debug("starting #{inspect(name)} on remote node #{remote_node}")

        {:ok, _pid} =
          Task.start(fn ->
            start_pid_remotely(remote_node, from, name, meta, state)
          end)

        :keep_state_and_data
    end
  end

  # Starts a process on a remote node. Handles failures with a retry mechanism
  defp start_pid_remotely(remote_node, from, name, meta, state, attempts \\ 0)

  defp start_pid_remotely(remote_node, from, name, meta, %TrackerState{} = state, attempts)
       when attempts <= @retry_max_attempts do
    try do
      case GenStateMachine.call(
             {tracker_name(state.endpoint), remote_node},
             {:track, name, meta},
             :infinity
           ) do
        {:ok, pid} ->
          debug("remotely started #{inspect(name)} (#{inspect(pid)}) on #{remote_node}")

          reply(from, {:ok, pid})

        {:error, {:already_registered, pid}} ->
          debug(
            "#{inspect(name)} already registered to #{inspect(pid)} on #{node(pid)}, registering locally"
          )

          # register named process that is unknown locally
          add_registration({name, pid, meta}, from, state)
          :ok

        {:error, {:noproc, _}} = err ->
          warn(
            "#{inspect(name)} could not be started on #{remote_node}: #{inspect(err)}, retrying operation after #{
              @retry_interval
            }ms.."
          )

          :timer.sleep(@retry_interval)
          start_pid_remotely(remote_node, from, name, meta, state, attempts + 1)

        {:error, :undef} ->
          warn(
            "#{inspect(name)} could not be started on #{remote_node}: target module not available on remote node, retrying operation after #{
              @retry_interval
            }ms.."
          )

          :timer.sleep(@retry_interval)
          start_pid_remotely(remote_node, from, name, meta, state, attempts + 1)

        {:error, _reason} = err ->
          warn("#{inspect(name)} could not be started on #{remote_node}: #{inspect(err)}")

          reply(from, err)
      end
    catch
      _, {:noproc, _} ->
        warn(
          "remote tracker on #{remote_node} went down during registration, retrying operation.."
        )

        start_pid_remotely(remote_node, from, name, meta, state)

      _, {{:nodedown, _}, _} ->
        warn("failed to start #{inspect(name)} on #{remote_node}: nodedown, retrying operation..")

        new_state = %{
          state
          | nodes: state.nodes -- [remote_node],
            strategy: state.strategy_impl.remove_node(state.strategy, remote_node)
        }

        case state.strategy_impl.key_to_node(new_state.strategy, name) do
          :undefined ->
            warn("failed to start #{inspect(name)} as no node available")
            reply(from, {:error, :no_node_available})

          new_node ->
            start_pid_remotely(new_node, from, name, meta, new_state)
        end

      kind, err ->
        error(Exception.format(kind, err, System.stacktrace()))
        warn("failed to start #{inspect(name)} on #{remote_node}: #{inspect(err)}")
        reply(from, {:error, err})
    end
  end

  defp start_pid_remotely(remote_node, from, name, _meta, _state, attempts) do
    warn(
      "#{inspect(name)} could not be started on #{remote_node}, failed to start after #{attempts} attempt(s)"
    )

    reply(from, {:error, :too_many_attempts})
  end

  ## Internal helpers

  # Send a reply message unless the recipient client is `nil`. Function always returns `:ok`
  defp reply(nil, _message), do: :ok
  defp reply(from, message), do: GenStateMachine.reply(from, message)

  defp broadcast_event(_endpoint, [], _clock, _event), do: :ok

  defp broadcast_event(endpoint, nodes, clock, event) do
    clock = Clock.peek(clock)

    :abcast = :rpc.abcast(nodes, tracker_name(endpoint), {:event, self(), clock, event})
    :ok
  end

  # Add a registration and reply to the caller with the result, then return the state transition
  defp add_registration({_name, _pid, _meta} = reg, from, state) do
    case register(reg, state) do
      {:ok, reply, new_state} ->
        reply(from, {:ok, reply})
        {:keep_state, new_state}

      {:error, reply, new_state} ->
        reply(from, {:error, reply})
        {:keep_state, new_state}
    end
  end

  # Add a registration and return the result of the add
  defp register(
         {name, pid, meta},
         %TrackerState{clock: clock, nodes: nodes, endpoint: endpoint} = state
       ) do
    case Registry.get_by_name(endpoint, name) do
      :undefined ->
        ref = Process.monitor(pid)
        lclock = Clock.event(clock)
        Registry.new!(endpoint, entry(name: name, pid: pid, ref: ref, meta: meta, clock: lclock))
        broadcast_event(endpoint, nodes, lclock, {:track, name, pid, meta})
        {:ok, pid, state}

      entry(pid: ^pid) ->
        # Not sure how this could happen, but hey, no need to return an error
        {:ok, pid, state}

      entry(pid: other_pid) ->
        debug(
          "conflicting registration for #{inspect(name)}: remote (#{inspect(pid)}) vs. local #{
            inspect(other_pid)
          }"
        )

        # Since there is already a registration, we need to check whether to kill the newly
        # created process
        pid_node = node(pid)
        current_node = Node.self()

        case meta do
          %{mfa: _} when pid_node == current_node ->
            # This was created via register_name/5, which means we need to kill the pid we started
            Process.exit(pid, :kill)

          _ ->
            # This was a pid started by something else, so we can ignore it
            :ok
        end

        {:error, {:already_registered, other_pid}, state}
    end
  end

  # Remove a registration, and return the result of the remove
  defp remove_registration(entry(pid: pid, ref: ref, clock: lclock) = obj, state) do
    Process.demonitor(ref, [:flush])
    Registry.remove(state.endpoint, obj)
    lclock = Clock.event(lclock)
    broadcast_event(state.endpoint, state.nodes, lclock, {:untrack, pid})
    {:ok, state}
  end

  defp remove_registration_by_pid(pid, state) do
    case Registry.get_by_pid(state.endpoint, pid) do
      :undefined ->
        {:ok, state}

      entries when is_list(entries) ->
        Enum.each(entries, fn entry ->
          remove_registration(entry, state)
        end)

        {:ok, state}
    end
  end

  defp add_meta_by_pid({key, value}, pid, state) do
    case Registry.get_by_pid(state.endpoint, pid) do
      :undefined ->
        {:ok, state}

      entries when is_list(entries) ->
        Enum.each(entries, fn entry(name: name, meta: old_meta, clock: lclock) ->
          new_meta = Map.put(old_meta, key, value)
          lclock = Clock.event(lclock)
          Registry.update(state.endpoint, name, meta: new_meta, clock: lclock)
          broadcast_event(state.endpoint, state.nodes, lclock, {:update_meta, new_meta, pid})
        end)

        {:ok, state}
    end
  end

  defp remove_meta_by_pid(key, pid, state) do
    case Registry.get_by_pid(state.endpoint, pid) do
      :undefined ->
        {:ok, state}

      entries when is_list(entries) ->
        Enum.each(entries, fn entry(name: name, meta: old_meta, clock: lclock) ->
          new_meta = Map.drop(old_meta, [key])
          lclock = Clock.event(lclock)
          Registry.update(state.endpoint, name, meta: new_meta, clock: lclock)
          broadcast_event(state.endpoint, state.nodes, lclock, {:update_meta, new_meta, pid})
        end)

        {:ok, state}
    end
  end

  @global_blacklist MapSet.new([~r/^remsh.*$/, ~r/^.+_upgrader_.+$/, ~r/^.+_maint_.+$/])
  # The list of configured ignore patterns for nodes
  # This is only applied if no blacklist is provided.
  defp node_blacklist(config) do
    config
    |> Keyword.get(:node_blacklist, [])
    |> MapSet.new()
    |> MapSet.union(@global_blacklist)
    |> MapSet.to_list()
  end

  # The list of configured whitelist patterns for nodes
  # If a whitelist is provided, any nodes which do not match the whitelist are ignored
  defp node_whitelist(config) do
    Keyword.get(config, :node_whitelist, [])
  end

  # Determine if a node should be ignored, even if connected
  # The whitelist and blacklist can contain literal strings, regexes, or regex strings
  # By default, all nodes are allowed, except those which are remote shell sessions
  # where the node name of the remote shell starts with `remsh` (relx, exrm, and distillery)
  # all use that prefix for remote shells.
  defp ignore_node?(config, node) do
    blacklist = node_blacklist(config)
    whitelist = node_whitelist(config)
    HashRing.Utils.ignore_node?(node, blacklist, whitelist)
  end

  # Used during anti-entropy checks to remove local registrations and replace them with the remote version
  defp resolve_incorrect_local_reg(
         _remote_node,
         entry(pid: lpid, clock: lclock) = lreg,
         entry(name: rname, pid: rpid, meta: rmeta, clock: rclock),
         state
       ) do
    # the remote registration is correct
    {:ok, new_state} = remove_registration(lreg, state)
    send(lpid, {:helios, :die})
    # add the remote registration
    ref = Process.monitor(rpid)
    lclock = Clock.join(lclock, rclock)

    Registry.new!(
      state.endpoint,
      entry(name: rname, pid: rpid, ref: ref, meta: rmeta, clock: lclock)
    )

    new_state
  end

  # Used during anti-entropy checks to remove remote registrations and replace them with the local version
  defp resolve_incorrect_remote_reg(
         remote_node,
         entry(pid: lpid, meta: lmeta),
         entry(name: rname, pid: rpid),
         state
       ) do
    GenStateMachine.cast({tracker_name(state.endpoint), remote_node}, {:untrack, rpid})
    send(rpid, {:helios, :die})

    GenStateMachine.cast(
      {tracker_name(state.endpoint), remote_node},
      {:track, rname, lpid, lmeta}
    )

    state
  end

  # A new node has been added to the cluster, we need to update the distribution strategy and handle shifting
  # processes to new nodes based on the new topology.
  defp nodeup(
         %TrackerState{nodes: nodes, strategy: strategy, strategy_impl: strategy_impl} = state,
         node
       ) do
    cond do
      node == Node.self() ->
        new_strategy =
          strategy
          |> strategy_impl.remove_node(state.self)
          |> strategy_impl.add_node(node)

        info("node name changed from #{state.self} to #{node}")
        {:ok, %{state | self: node, strategy: new_strategy}}

      Enum.member?(nodes, node) ->
        {:ok, state}

      ignore_node?(state.config, node) ->
        {:ok, state}

      :else ->
        ensure_swarm_started_on_remote_node(state, node)
    end
  end

  defp ensure_swarm_started_on_remote_node(state, node, attempts \\ 0)

  defp ensure_swarm_started_on_remote_node(
         %TrackerState{nodes: nodes, strategy: strategy} = state,
         node,
         attempts
       )
       when attempts <= @retry_max_attempts do
    otp_app = state.endpoint.__app__()

    case :rpc.call(node, :application, :which_applications, []) do
      app_list when is_list(app_list) ->
        case List.keyfind(app_list, otp_app, 0) do
          {^otp_app, _, _} ->
            info("nodeup #{node}")

            new_state = %{
              state
              | nodes: [node | nodes],
                strategy: state.strategy_impl.add_node(strategy, node)
            }

            {:ok, new_state, {:topology_change, {:nodeup, node}}}

          nil ->
            debug(
              "nodeup for #{node} was ignored because :#{otp_app} application " <>
                "not started yet, will retry in #{@retry_interval}ms.."
            )

            Process.send_after(
              self(),
              {:ensure_swarm_started_on_remote_node, node, attempts + 1},
              @retry_interval
            )

            {:ok, state}
        end

      other ->
        warn("nodeup for #{node} was ignored because: #{inspect(other)}")
        {:ok, state}
    end
  end

  defp ensure_swarm_started_on_remote_node(%TrackerState{} = state, node, attempts) do
    otp_app = state.endpoint.__app__()

    warn(
      "nodeup for #{node} was ignored because :#{otp_app} failed to start after #{attempts} attempt(s)"
    )

    {:ok, state}
  end

  # A remote node went down, we need to update the distribution strategy and handle restarting/shifting processes
  # as needed based on the new topology
  defp nodedown(%TrackerState{nodes: nodes, strategy: strategy} = state, node) do
    if Enum.member?(nodes, node) do
      info("nodedown #{node}")
      strategy = state.strategy_impl.remove_node(strategy, node)

      pending_reqs =
        Enum.filter(state.pending_sync_reqs, fn
          ^node -> false
          _ -> true
        end)

      new_state = %{
        state
        | nodes: nodes -- [node],
          strategy: strategy,
          pending_sync_reqs: pending_reqs
      }

      {:ok, new_state, {:topology_change, {:nodedown, node}}}
    else
      {:ok, state}
    end
  end

  defp get_registry_snapshot(endpoint) do
    snapshot = Registry.snapshot(endpoint)

    Enum.map(snapshot, fn entry(name: name, pid: pid, ref: ref, meta: meta, clock: clock) ->
      entry(name: name, pid: pid, ref: ref, meta: meta, clock: Clock.peek(clock))
    end)
  end
end
