defmodule Helios.Context do
  @moduledoc """
  Represent execution context for single message/command sent to helios endpoint.
  """

  defmodule NotSentError do
    defexception message: "a response was neither set nor sent from the connection"

    @moduledoc """
    Error raised when no response is sent in a request
    """
  end

  defmodule AlreadySentError do
    defexception message: "the response was already sent"

    @moduledoc """
    Error raised when trying to modify or send an already sent response
    """
  end

  alias Helios.Context
  alias Helios.EventJournal.Messages.EventData

  @type opts :: binary | tuple | atom | integer | float | [opts] | %{opts => opts}

  # module that implements Aggregate behaviour
  @type aggregate_module :: module
  # user shared assigns
  @type assigns :: %{atom => any}
  # id that uniquely identifies request from which context originates
  @type request_id :: String.t()
  # id with which command correlates
  @type correlation_id :: String.t() | nil
  # single event generated by aggregate
  @type event :: struct()
  # events generated by command execution
  @type events :: nil | event | [event]
  # indicates that processing pipeline halted and none of other plugs that waiths for execution will be excuted
  @type halted :: boolean
  # pid to which reposponse should be reply-ed
  @type owner :: pid
  # command parameters
  @type params :: map | struct
  # remote caller pid
  @type peer :: pid
  # plugin private assigns
  @type private :: map
  # status of current context
  @type status :: :init | :executing | :executed | :commiting | :success | :failed

  @type response :: any

  @type t :: %Context{
          adapter: {module, term},
          assigns: assigns,
          method: atom,
          before_send: list(),
          path_info: [binary],
          request_id: request_id,
          correlation_id: correlation_id,
          events: events,
          halted: halted,
          owner: owner,
          params: params,
          path_params: params,
          peer: peer,
          private: private,
          retry: integer,
          state: :unset | :set | :sent,
          status: status,
          response: response
        }

  defstruct adapter: nil,
            assigns: %{},
            before_send: [],
            path_info: [],
            request_id: nil,
            correlation_id: nil,
            method: nil,
            events: nil,
            halted: false,
            handler: nil,
            owner: nil,
            params: %{},
            path_params: %{},
            peer: nil,
            private: %{},
            retry: 0,
            state: :unset,
            status: :init,
            response: nil

  @already_sent {:plug_ctx, :sent}
  @unsent [:unset, :set]
  @doc """
  Assigns a value to a key in the context.

  ## Examples

      iex> ctx.assigns[:hello]
      nil
      iex> ctx = assign(ctx, :hello, :world)
      iex> ctx.assigns[:hello]
      :world

  """
  @spec assign(Context.t(), atom, any) :: Context.t()
  def assign(%Context{assigns: assigns} = ctx, key, value) when is_atom(key) do
    %{ctx | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Assigns multiple values to keys in the context.

  Equivalent to multiple calls to `assign/3`.

  ## Examples

      iex> ctx.assigns[:hello]
      nil
      iex> ctx = merge_assigns(ctx, hello: :world)
      iex> ctx.assigns[:hello]
      :world

  """
  @spec merge_assigns(Context.t(), Keyword.t()) :: Context.t()
  def merge_assigns(%Context{assigns: assigns} = ctx, keyword) when is_list(keyword) do
    %{ctx | assigns: Enum.into(keyword, assigns)}
  end

  @doc """
  Assigns a new **private** key and value in the context.

  This storage is meant to be used by libraries and frameworks to avoid writing
  to the user storage (the `:assigns` field). It is recommended for
  libraries/frameworks to prefix the keys with the library name.

  For example, if some plug needs to store a `:hello` key, it
  should do so as `:plug_hello`:

      iex> ctx.private[:plug_hello]
      nil
      iex> ctx = put_private(ctx, :plug_hello, :world)
      iex> ctx.private[:plug_hello]
      :world

  """
  @spec put_private(Context.t(), atom, term) :: Context.t()
  def put_private(%Context{private: private} = ctx, key, value) when is_atom(key) do
    %{ctx | private: Map.put(private, key, value)}
  end

  @doc """
  Assigns multiple **private** keys and values in the context.

  Equivalent to multiple `put_private/3` calls.

  ## Examples

      iex> ctx.private[:plug_hello]
      nil
      iex> ctx = merge_private(ctx, plug_hello: :world)
      iex> ctx.private[:plug_hello]
      :world
  """
  @spec merge_private(Context.t(), Keyword.t()) :: Context.t()
  def merge_private(%Context{private: private} = ctx, keyword) when is_list(keyword) do
    %{ctx | private: Enum.into(keyword, private)}
  end

  @doc """
  Halts the Context pipeline by preventing further plugs downstream from being
  invoked. See the docs for `Helios.Context.Builder` for more information on halting a
  command context pipeline.
  """
  @spec halt(Context.t()) :: Context.t()
  def halt(%Context{} = ctx) do
    %{ctx | halted: true}
  end

  @doc """
  Emits given event or events. If events is equal to nil, then it will ignore call.
  """
  @spec emit(ctx :: Context.t(), Context.events()) :: Context.t()
  def emit(%Context{events: events} = ctx, to_emit) do
    events = List.wrap(events)

    to_emit =
      to_emit
      |> List.wrap()
      |> Enum.map(fn event ->
        metadata =
          [
            # todo: Metadata builder as plug??!?!
            correlation_id: ctx.correlation_id,
            causation_id: ctx.request_id,
            emitted_at: DateTime.utc_now()
          ]
          |> Enum.filter(fn {_, v} -> v != nil end)

        %EventData{
          id: Keyword.get(UUID.info!(UUID.uuid4()), :binary, :undefined),
          type: Atom.to_string(event.__struct__),
          data: event,
          metadata: Enum.into(metadata, %{})
        }
      end)

    %{ctx | events: events ++ to_emit}
  end

  @doc """
  Set response to context. Response is success
  """
  @spec ok(Context.t(), any()) :: Context.t()
  def ok(ctx, message \\ :ok)

  def ok(%Context{state: :set}, _message) do
    raise RuntimeError, "Response already set!"
  end

  def ok(%Context{} = ctx, message) do
    %{ctx | response: message, state: :set, status: :executed}
  end

  @spec error(Context.t(), any()) :: Context.t()
  def error(%Context{} = ctx, reason) do
    %{ctx | halted: true, response: reason, state: :set, status: :failed}
  end

  @spec send_resp(t) :: t | no_return
  def send_resp(ctx)

  def send_resp(%Context{state: :unset}) do
    raise ArgumentError, "cannot send a response that was not set"
  end

  def send_resp(%Context{adapter: {adapter, payload}, state: :set, owner: owner} = ctx) do
    ctx = run_before_send(ctx, :set)

    {:ok, body, payload} = adapter.send_resp(payload, ctx.status, ctx.response)

    send(owner, @already_sent)
    %{ctx | adapter: {adapter, payload}, response: body, state: :sent}
  end

  def send_resp(%Context{}) do
    raise AlreadySentError
  end

  @doc """
  Registers a callback to be invoked before the response is sent.

  Callbacks are invoked in the reverse order they are defined (callbacks
  defined first are invoked last).
  """
  @spec register_before_send(t, (t -> t)) :: t
  def register_before_send(%Context{state: state}, _callback)
      when not (state in @unsent) do
    raise AlreadySentError
  end

  def register_before_send(%Context{before_send: before_send} = ctx, callback)
      when is_function(callback, 1) do
    %{ctx | before_send: [callback | before_send]}
  end

  defp run_before_send(%Context{before_send: before_send} = ctx, new) do
    ctx = Enum.reduce(before_send, %{ctx | state: new}, & &1.(&2))

    if ctx.state != new do
      raise ArgumentError, "cannot send/change response from run_before_send callback"
    end

    ctx
  end
end

defimpl Inspect, for: Helios.Aggregate.Context do
  def inspect(ctx, opts) do
    ctx =
      if opts.limit == :infinity do
        ctx
      else
        update_in(ctx.events, fn {events, data} ->
          event_types =
            Enum.map(data, fn %{__struct__: event_module} ->
              "##{inspect(event_module)}<...>"
            end)

          {events, event_types}
        end)
      end

    Inspect.Any.inspect(ctx, opts)
  end
end

defimpl Collectable, for: Helios.Context do
  def into(data) do
    {data,
     fn data, _ ->
       data
     end}
  end
end
