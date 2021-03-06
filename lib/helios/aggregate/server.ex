defmodule Helios.Aggregate.Server do
  @moduledoc false
  use GenServer
  use Helios.Logger
  alias Helios.Context
  alias Helios.Pipeline.MessageHandlerClauseError
  alias Helios.Aggregate.SnapshotOffer
  alias Helios.Registry
  # alias Helios.Aggregate.WrapperError

  @idle_timeout 30_000
  # events
  @snapshot_every 1000

  @type key :: integer() | String.t()
  @type status :: :recovering | {:executing, Context.t()} | :ready
  @type server_state :: %__MODULE__{
          id: term,
          aggregate_module: module,
          aggregate: struct,
          last_sequence_no: integer,
          last_snapshot_version: integer,
          status: status,
          journal: module,
          last_activity_at: term
        }

  defstruct id: nil,
            aggregate_module: nil,
            aggregate: nil,
            last_sequence_no: -1,
            last_snapshot_version: -1,
            status: :recovering,
            buffer: :queue.new(),
            journal: nil,
            last_activity_at: nil

  # CLIENT

  @spec call(ctx :: Context.t(), any) :: Context.t()
  def call(%{private: private} = ctx, _opts) do
    %{
      helios_plug_key: key,
      helios_plug: plug,
      helios_endpoint: endpoint
    } = private

    id = Map.get(ctx.params, key)

    {:ok, pid} =
      Registry.whereis_or_register(
        endpoint,
        plug.persistance_id(id),
        Helios.Aggregate.Supervisor,
        :register,
        [endpoint, plug, id]
      )

    timeout = Map.get(private, :helios_timeout, 5_000)
    GenServer.call(pid, {:execute, ctx}, timeout)
  end

  @spec start_link(atom, {module(), key()}, GenServer.options()) :: GenServer.on_start()
  def start_link(otp_app, {module, id}, opts \\ []) do
    GenServer.start_link(__MODULE__, [otp_app, module, id], opts)
  end

  # SERVER

  @impl GenServer
  @spec init([...]) :: {:ok, __MODULE__.server_state()}
  def init([otp_app, module, id]) do
    default_journal = Application.get_env(:helios, :default_journal)

    journal =
      otp_app
      |> Application.get_env(module, [])
      |> Keyword.get(:journal, default_journal)

    state =
      struct(
        __MODULE__,
        id: id,
        aggregate_module: module,
        journal: journal,
        status: :recovering,
        last_activity_at: DateTime.utc_now()
      )

    case module.new(id: id, otp_app: otp_app) do
      {:ok, aggregate} ->
        :ok = GenServer.cast(self(), :recover)
        {:ok, %{state | aggregate: aggregate}}

      {:stop, _} = stop ->
        stop

      :ignore ->
        :ignore

      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  @doc false
  @impl true
  def handle_call({:execute, ctx}, from, %{status: :ready} = state) do
    new_ctx = %{ctx | owner: from}
    Logger.metadata(request_id: ctx.request_id)
    handle_execute(new_ctx, state)
  end

  def handle_call({:execute, ctx}, from, %{buffer: buffer} = state) do
    new_ctx = %{ctx | owner: from}
    buffer = :queue.in({:execute, new_ctx}, buffer)
    {:noreply, %{state | buffer: buffer}}
  end

  # called when a handoff has been initiated due to changes
  # in cluster topology, valid response values are:
  #
  #   - `:restart`, to simply restart the process on the new node
  #   - `{:resume, state}`, to hand off some state to the new process
  #   - `:ignore`, to leave the process running on its current node
  #
  def handle_call({:helios, :begin_handoff}, _from, s) do
    debug(fn -> "Handing off state" end)
    {:stop, :shutdown, {:resume, s}, s}
  end

  @doc false
  @impl true
  def handle_cast({:execute, ctx}, %{status: :ready} = state) do
    Logger.metadata(request_id: ctx.request_id)
    handle_execute(ctx, state)
  end

  def handle_cast({:execute, ctx}, %{buffer: buffer} = state) do
    buffer = :queue.in({:execute, ctx}, buffer)
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_cast(:recover, %{aggregate_module: module, id: id} = state) do
    state =
      state
      |> load_snapshot()
      |> load_events()
      |> ready()
      |> schedule_shutdown()

    debug(fn ->
      case state.last_sequence_no do
        -1 ->
          "Spawned new aggregate `{#{module}, #{id}}`"

        version ->
          "Aggregate `{#{module}, #{id}}` recoverd to version #{version}."
      end
    end)

    {:noreply, state}
  end

  # called after the process has been restarted on its new node,
  # and the old process' state is being handed off. This is only
  # sent if the return to `begin_handoff` was `{:resume, state}`.
  # **NOTE**: This is called *after* the process is successfully started,
  # so make sure to design your processes around this caveat if you
  # wish to hand off state like this.
  def handle_cast({:helios, :end_handoff, state}, s) do
    s =
      s
      |> Map.put(:buffer, :queue.join(state.buffer, s.buffer))
      |> maybe_dequeue()
      |> schedule_shutdown()

    {:noreply, s}
  end

  # called when a network split is healed and the local process
  # should continue running, but a duplicate process on the other
  # side of the split is handing off its state to us. You can choose
  # to ignore the handoff state, or apply your own conflict resolution
  # strategy
  def handle_cast({:helios, :resolve_conflict, remote}, local) do
    debug(fn -> "Resolving conflict with remote #{inspect(remote.peer)}." end)

    debug(fn ->
      "Remote buffer of #{:queue.len(remote.buffer)} pending commands is merget into local process buffer."
    end)

    state =
      local
      |> Map.put(:buffer, :queue.join(remote.buffer, local.buffer))
      |> maybe_dequeue()
      |> schedule_shutdown()

    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info(:idlechk, %{buffer: buffer, last_activity_at: inactive_since} = state) do
    with {:buffer, 0} <- {:buffer, :queue.len(buffer)},
         {:message_queue_len, 0} <- Process.info(self(), :message_queue_len),
         true <- DateTime.diff(DateTime.utc_now(), inactive_since, :millisecond) > @idle_timeout do
      {:stop, :normal, state}
    else
      {:buffer, _} ->
        s =
          state
          |> maybe_dequeue()
          |> schedule_shutdown()

        {:noreply, s}

      {:message_queue_len, _} ->
        {:noreply, schedule_shutdown(state)}

      false ->
        {:noreply, schedule_shutdown(state)}
    end
  end

  # this message is sent when this process should die
  # because it is being moved, use this as an opportunity
  # to clean up
  def handle_info({:helios, :die}, state) do
    {:stop, :shutdown, state}
  end

  ## Catch-all messages
  @doc false
  @impl true
  def terminate(reason, %{aggregate_module: mod, aggregate: aggregate}) do
    if function_exported?(mod, :terminate, 2) do
      mod.terminate(reason, aggregate)
    else
      :ok
    end
  end

  @doc false
  @impl true
  def code_change(old_vsn, %{aggregate_aggregate: mod, aggregate: aggregate} = s, extra) do
    if function_exported?(mod, :code_change, 3) do
      case mod.code_change(old_vsn, aggregate, extra) do
        {:ok, aggregate} -> {:ok, %{s | aggregate: aggregate}}
        other -> other
      end
    else
      {:ok, s}
    end
  end

  @doc false
  @impl true
  def format_status(opt, [pdict, %{aggregate_module: mod, aggregate: aggregate} = s]) do
    case {function_exported?(mod, :format_status, 2), opt} do
      {true, :normal} ->
        data = [{~c(Aggregate), aggregate}] ++ format_status_for_subscription(s)
        format_status(mod, opt, pdict, aggregate, data: data)

      {true, :terminate} ->
        format_status(mod, opt, pdict, aggregate, aggregate)

      {false, :normal} ->
        [data: [{~c(Aggregate), aggregate}] ++ format_status_for_subscription(s)]

      {false, :terminate} ->
        aggregate
    end
  end

  defp format_status(mod, opt, pdict, state, default) do
    try do
      mod.format_status(opt, [pdict, state])
    catch
      _, _ ->
        default
    end
  end

  defp format_status_for_subscription(%{
         conn: conn,
         module: module,
         sub: subscription
       }) do
    [
      {~c(Connection), conn},
      {~c(Subscription), subscription},
      {~c(Implementation), module}
    ]
  end

  # SERVER PRIVATE
  defp handle_execute(ctx, %{aggregate: aggregate} = s) do
    ctx =
      ctx
      |> put_aggregate(aggregate)
      |> try_execute()

    new_state =
      s
      |> Map.put(:status, {:executing, ctx})
      |> maybe_commit()
      |> maybe_reply()
      |> take_snapshot()
      |> maybe_dequeue()

    {:noreply, %{new_state | last_activity_at: DateTime.utc_now()}}
  end

  defp put_aggregate(ctx, aggregate) do
    %{ctx | assigns: Map.put(ctx.assigns, :aggregate, aggregate)}
  end

  defp try_execute(%Context{status: :init, state: state, private: %{helios_plug: plug}} = ctx)
       when not (state in [:set, :send]) do
    ctx = %{ctx | status: :executing}

    ctx
    |> plug.call(ctx.private.helios_plug_handler)
  rescue
    error in MessageHandlerClauseError ->
      %{ctx | status: :failed, halted: true, response: error}
  catch
    error -> %{ctx | status: :failed, halted: true, response: error}
  end

  defp maybe_commit(%{status: {:executing, %{status: :executed, events: e} = ctx}} = s)
       when not is_list(e) do
    events = List.wrap(e)
    ctx = %{ctx | events: events}
    maybe_commit(%{s | status: {:executing, ctx}})
  end

  defp maybe_commit(%{status: {:executing, %{status: :executed, events: events} = ctx}} = s)
       when length(events) > 0 do
    %{aggregate_module: module, journal: journal} = s
    stream = module.persistance_id(s.id)

    # todo: async commiting
    case journal.append_to_stream(stream, events, s.last_sequence_no) do
      {:ok, event_number} ->
        aggregate =
          Enum.reduce(events, s.aggregate, fn event, agg ->
            module.apply_event(event.data, agg)
          end)

        new_ctx =
          ctx
          |> Map.put(:status, :success)
          |> put_aggregate(aggregate)

        %{
          s
          | status: {:executing, new_ctx},
            last_sequence_no: event_number,
            aggregate: aggregate
        }

      {:error, reason} ->
        raise RuntimeError, reason
    end
  end

  defp maybe_commit(%{status: {:executing, %{status: :executed} = ctx}} = s) do
    new_ctx = %{ctx | status: :success}
    %{s | status: {:executing, new_ctx}}
  end

  defp maybe_commit(s), do: s

  defp maybe_reply(%{status: {:executing, %{status: :failed} = ctx}} = s) do
    case ctx.owner do
      nil ->
        warn(fn ->
          "Failed to execute command #{ctx.private.helios_plug_handler} with " <>
            "reson #{ctx.response} but no owner found in context to report to!!!"
        end)

      pid when is_pid(pid) ->
        send(pid, ctx)

      {pid, _tag} = dest when is_pid(pid) ->
        :ok = GenServer.reply(dest, ctx)
    end

    %{s | status: :ready}
  end

  defp maybe_reply(%{status: {:executing, %{status: :success} = ctx}} = s) do
    case ctx.owner do
      nil ->
        warn(fn ->
          "Failed to execute command #{ctx.private.helios_plug_handler} with " <>
            " reson #{ctx.response} but no owner found in context to report to!!!"
        end)

      pid when is_pid(pid) ->
        send(pid, ctx)

      {pid, _tag} = dest when is_pid(pid) ->
        GenServer.reply(dest, ctx)
    end

    %{s | status: :ready}
  end

  defp maybe_reply(s), do: s

  defp take_snapshot(%{status: {:executing, %{status: :success}}} = s) do
    %{
      journal: journal,
      last_sequence_no: event_number,
      last_snapshot_version: snapshot_version,
      id: id,
      aggregate_module: module,
      aggregate: aggregate
    } = s

    with true <- function_exported?(module, :to_snapshot, 1),
         true <- event_number > 0,
         0 <- rem(event_number, @snapshot_every) do
      payload = module.to_snapshot(aggregate)
      stream = module.persistance_id(id)

      {:ok, version} =
        journal.append_to_stream(
          "snapshot::#{stream}",
          [%{data: payload, metadata: %{from_event_number: event_number}}],
          snapshot_version
        )

      %{s | last_snapshot_version: version}
    else
      _ -> s
    end
  rescue
    e ->
      warn(fn ->
        "Snapshot is NOT taken! Check error below. While it is safe to ignore " <>
          "this warning, keep in mind that aggregate recovery will take longer " <>
          "than it is desired if this error happenes again for same aggregate.\n" <>
          Exception.format(:error, e, __STACKTRACE__)
      end)

      # ignore take snapshot errors
      s
  end

  defp take_snapshot(s), do: s

  defp maybe_dequeue(%{status: :ready, buffer: buffer} = s) do
    do_dequeue(:queue.out(buffer), s)
  end

  defp maybe_dequeue(s), do: s

  defp do_dequeue({value, buffer}, s) do
    case value do
      :empty ->
        %{s | buffer: :queue.new()}

      {:value, {:execute, ctx}} ->
        GenServer.cast(self(), {:execute, ctx})
        do_dequeue(:queue.out(buffer), s)
    end
  end

  defp load_snapshot(%{aggregate_module: module} = state) do
    unless function_exported?(module, :from_snapshot, 2) do
      state
    else
      %{
        journal: journal,
        aggregate: aggregate,
        aggregate_module: module,
        id: id
      } = state

      end_of_stream = Helios.EventJournal.stream_end()
      stream = module.persistance_id(id)

      with {:ok, %{events: [event | _]}} <-
             journal.read_stream_events_backward("snapshot::#{stream}", end_of_stream, 1),
           snapshot <- SnapshotOffer.from_journal(event),
           {:ok, aggregate} <- module.from_snapshot(snapshot, aggregate) do
        %{
          state
          | last_sequence_no: snapshot.event_number,
            aggregate: aggregate,
            last_snapshot_version: snapshot.snapshot_number
        }
      else
        {:ok, %{events: []}} ->
          %{state | aggregate: aggregate}

        {:error, error} ->
          debug(fn -> "SnapshotOffer skipped due: #{inspect(error)}" end)
          %{state | aggregate: aggregate}

        {:skip, aggregate} ->
          debug(fn ->
            "SnapshotOffer rejected by user code, recovering from all stream events."
          end)

          %{state | aggregate: aggregate}
      end
    end
  end

  defp load_events(
         %{
           journal: journal,
           aggregate_module: module,
           id: id,
           last_sequence_no: last_sequence_no
         } = state
       ) do
    stream = module.persistance_id(id)

    take = 100
    start_from = if last_sequence_no < 0, do: 0, else: last_sequence_no
    journal_fn = :read_stream_events_forward

    event_stream =
      Stream.resource(
        fn ->
          [stream, start_from, take]
        end,
        fn args ->
          case apply(journal, journal_fn, args) do
            {:ok, %{events: events}} when events == [] ->
              {:halt, args}

            {:ok, rse} ->
              {rse.events, [stream, rse.next_event_number, take]}

            {:error, :no_stream} ->
              {:halt, args}

            {:error, error} ->
              raise RuntimeError, "Failed to recover aggregate due `#{inspect(error)}`"
          end
        end,
        fn x -> x end
      )

    Enum.reduce(event_stream, state, fn persisted_event, s ->
      aggregate = module.apply_event(persisted_event.data, s.aggregate)
      %{s | last_sequence_no: persisted_event.event_number, aggregate: aggregate}
    end)
  end

  defp schedule_shutdown(%{last_activity_at: inactive_since} = state) do
    diff = DateTime.diff(DateTime.utc_now(), inactive_since, :millisecond)
    timeout = @idle_timeout - diff
    timeout = if timeout <= 0, do: 0, else: timeout
    Process.send_after(self(), :idlechk, timeout)
    state
  end

  defp ready(state) do
    %{state | status: :ready}
  end
end
