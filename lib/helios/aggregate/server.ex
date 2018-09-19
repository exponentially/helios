defmodule Helios.Aggregate.Server do
  use GenServer
  alias Helios.Pipeline.Context
  alias Helios.Aggregate.CommandHandlerClauseError
  # alias Helios.Aggregate.WrapperError

  @type status :: :recovering | {:executing, Context.t()} | :ready
  @type server_state :: %__MODULE__{
          id: term,
          aggregate_module: module,
          aggregate: struct,
          last_sequence_no: integer,
          last_snapshot_version: integer,
          status: status,
          journal: module
        }

  defstruct id: nil,
            aggregate_module: nil,
            aggregate: nil,
            last_sequence_no: -1,
            last_snapshot_version: -1,
            status: :recovering,
            buffer: :queue.new(),
            journal: nil

  # CLIENT

  @spec start_link({module(), integer() | String.t()}, GenServer.options()) ::
          GenServer.on_start()
  def start_link({module, id}, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, id}, opts)
  end

  # SERVER

  @impl true
  @spec init({atom(), module(), term()}) :: {:ok, __MODULE__.server_state()}
  def init({otp_app, module, id}) do
    opts =
      Application.get_env(otp_app, module, [])
      |> Keyword.put_new(:journal, Helios.EventJournal.Adapter.Memory)

    state =
      struct(
        __MODULE__,
        id: id,
        aggregate_module: module,
        aggregate: struct(module),
        journal: Keyword.get(opts, :journal)
      )

    :ok = GenServer.cast(self(), :recover)
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, ctx}, from, %{status: :ready} = state) do
    handle_execute(ctx, from, state)
  end

  def handle_call({:execute, ctx}, from, %{status: {:executing, _}, buffer: buffer} = state) do
    new_ctx = %{ctx | owner: from}
    buffer = :queue.in({:execute, new_ctx}, buffer)
    {:noreply, %{state | buffer: buffer}}
  end

  @impl true
  def handle_cast({:execute, ctx}, %{status: :ready} = state) do
    handle_execute(ctx, ctx.owner, state)
  end

  def handle_cast({:execute, ctx}, %{status: {:executing, _}, buffer: buffer} = state) do
    buffer = :queue.in({:execute, ctx}, buffer)
    {:noreply, %{state | buffer: buffer}}
  end

  # SERVER PRIVATE
  defp handle_execute(ctx, from, s) when is_map(ctx) do
    ctx =
      ctx
      |> Map.put(:aggregate, s.state)
      |> Map.put(:aggregate_module, s.aggregate_module)
      |> Map.put(:owner, from)
      |> Map.put(:peer, self())
      |> try_execute()

    new_state =
      s
      |> Map.put(:status, {:executing, ctx})
      |> maybe_commit()
      |> maybe_reply()
      |> maybe_dequeue()

    {:noreply, new_state}
  end

  defp try_execute(%{status: :init, aggregate_module: module} = ctx) do
    ctx = %{ctx | status: :executing}

    ctx =
      try do
        ctx
        |> module.call(ctx.command)
        |> Map.put(:status, :executed)
      rescue
        error in CommandHandlerClauseError ->
          %{ctx | status: :failed, halted: true, response: error}
      catch
        error -> %{ctx | status: :failed, halted: true, response: error}
      end

    ctx
  end

  defp maybe_commit(%{status: {:executing, %{status: :executed, events: e} = ctx}} = s)
       when is_list(e) == false do
    events = List.wrap(e)
    ctx = %{ctx | events: events}
    maybe_commit(%{s | status: {:executing, ctx}})
  end

  defp maybe_commit(%{status: {:executing, %{status: :executed, events: events} = ctx}} = s)
       when length(events) > 0 do
    %{journal: journal, aggregate_module: module, id: id, last_sequence_no: expected_version} = s
    stream = module.persistance_id(id)

    # todo: async commiting
    case apply(journal, :append_to_stream, [stream, events, expected_version]) do
      {:ok, event_number} ->
        new_ctx = %{ctx | status: :success}
        %{s | status: {:executing, new_ctx}, last_sequence_no: event_number}

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
    :ok = GenServer.reply(ctx.owner, {:error, response})
    %{s | status: :ready}
  end

  defp maybe_reply(%{status: {:executing, %{status: :success, response: response} = ctx}} = s) do
    :ok = GenServer.reply(ctx.owner, {:ok, response})
    %{s | status: :ready}
  end

  defp maybe_reply(s), do: s

  defp maybe_dequeue(%{status: :ready, buffer: buffer} = s) do
    do_dequeue(:queue.out(buffer), s)
  end

  defp do_dequeue({:empty, {[], []} = buffer}, s), do: %{s | buffer: buffer}

  defp do_dequeue({{:value, {:execute, ctx}}, buffer}, s) do
    GenServer.cast(self(), {:execute, ctx})
    do_dequeue(:queue.out(buffer), s)
  end
end
