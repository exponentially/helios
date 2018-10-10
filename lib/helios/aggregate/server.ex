defmodule Helios.Aggregate.Server do
  @moduledoc false
  use GenServer
  require Logger
  alias Helios.Context
  alias Helios.Pipeline.MessageHandlerClauseError
  import Helios.Registry, only: [whereis_or_register: 5]
  # alias Helios.Aggregate.WrapperError

  @idle_timeout 30_000

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

  def call(%{private: private} = ctx, _) do
    %{helios_plug_key: key, helios_plug: plug, helios_endpoint: endpoint} = private
    id = Map.get(ctx.params, key)

    {:ok, pid} =
      whereis_or_register(
        endpoint,
        plug.persistance_id(id),
        Helios.Aggregate.Supervisor,
        :register,
        [endpoint, plug, id]
      )

    GenServer.call(pid, {:execute, ctx}, Map.get(private, :helios_timeout, 5_000))
  end

  @spec start_link(
          otp_app :: atom,
          aggregate :: {module(), integer() | String.t()},
          opts :: GenServer.options()
        ) :: GenServer.on_start()
  def start_link(otp_app, {module, id}, opts \\ []) do
    GenServer.start_link(__MODULE__, [otp_app, module, id], opts)
  end

  # SERVER

  @impl true
  @spec init({atom(), module(), term()}) :: {:ok, __MODULE__.server_state()}
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
        aggregate: struct(module),
        journal: journal,
        status: :recovering,
        last_activity_at: DateTime.utc_now()
      )

    :ok = GenServer.cast(self(), :recover)
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, ctx}, from, %{status: :ready} = state) do
    new_ctx = %{ctx | owner: from}
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
    Logger.debug("Handing off state")
    {:stop, :shutdown, {:resume, s}, s}
  end

  @impl true
  def handle_cast({:execute, ctx}, %{status: :ready} = state) do
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

    Logger.debug(fn ->
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
    Logger.debug(fn -> "Resolving conflict with remote #{inspect(remote.peer)}." end)

    Logger.debug(fn ->
      "Remote buffer of #{:queue.len(remote.buffer)} pending commands is merget into local process buffer."
    end)

    state =
      local
      |> Map.put(:buffer, :queue.join(remote.buffer, local.buffer))
      |> maybe_dequeue()
      |> schedule_shutdown()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        :idlechk,
        %{buffer: buffer, last_activity_at: inactive_since} = state
      ) do
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

  def handle_info(msg, state), do: super(msg, state)

  # SERVER PRIVATE
  defp handle_execute(ctx, %{aggregate: aggregate} = s) do
    ctx =
      ctx
      |> Context.put_private(:helios_plug_state, aggregate)
      |> try_execute()

    new_state =
      s
      |> Map.put(:status, {:executing, ctx})
      |> maybe_commit()
      |> maybe_reply()
      |> maybe_dequeue()

    {:noreply, %{new_state | last_activity_at: DateTime.utc_now()}}
  end

  defp try_execute(%Context{status: :init, state: state, private: %{helios_plug: plug}} = ctx)
       when not (state in [:set, :send]) do
    ctx = %{ctx | status: :executing}

    ctx
    |> plug.call(ctx.private.helios_plug_handler)
    |> Map.put(:status, :executed)
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
    stream = s.aggregate_module.persistance_id(s.id)

    # todo: async commiting
    case apply(s.journal, :append_to_stream, [stream, events, s.last_sequence_no]) do
      {:ok, event_number} ->
        aggregate =
          Enum.reduce(events, s.aggregate, fn event, agg ->
            apply(s.aggregate_module, :apply_event, [event.data, agg])
          end)

        new_ctx = %{
          ctx
          | status: :success,
            private: %{ctx.private | helios_plug_state: aggregate}
        }

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

  defp maybe_reply(%{status: {:executing, %{status: :failed, response: response} = ctx}} = s) do
    case ctx.owner do
      nil ->
        Logger.warn(
          "Failed to execute command #{ctx.private.helios_plug_handler} with reson #{response} but no owner found in context to report to!!!"
        )

      pid when is_pid(pid) ->
        send(pid, ctx)

      {pid, _tag} = dest when is_pid(pid) ->
        :ok = GenServer.reply(dest, ctx)
    end

    %{s | status: :ready}
  end

  defp maybe_reply(%{status: {:executing, %{status: :success, response: response} = ctx}} = s) do
    case ctx.owner do
      nil ->
        Logger.warn(
          "Failed to execute command #{ctx.private.helios_plug_handler} with reson #{response} but no owner found in context to report to!!!"
        )

      pid when is_pid(pid) ->
        send(pid, ctx)

      {pid, _tag} = dest when is_pid(pid) ->
        :ok = GenServer.reply(dest, ctx)
    end

    %{s | status: :ready}
  end

  defp maybe_reply(s), do: s

  defp maybe_dequeue(%{status: :ready, buffer: buffer} = s) do
    do_dequeue(:queue.out(buffer), s)
  end

  defp maybe_dequeue(s), do: s

  defp do_dequeue({:empty, {[], []} = buffer}, s), do: %{s | buffer: buffer}

  defp do_dequeue({{:value, {:execute, ctx}}, buffer}, s) do
    GenServer.cast(self(), {:execute, ctx})
    do_dequeue(:queue.out(buffer), s)
  end

  defp load_snapshot(state) do
    # TODO: snapshot store
    state
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
              raise RuntimeError, "Failed to recover aggregate due #{inspect(error)}"
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
