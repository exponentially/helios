defmodule Helios.Pipeline.Context do
  @moduledoc """
  Represent execution context for single message/command sent to helios endpoint.
  """

  alias Helios.Pipeline.Context
  alias Helios.EventJournal.Messages.EventData

  @type opts :: binary | tuple | atom | integer | float | [opts] | %{opts => opts}

  # module that implements Aggregate behaviour
  @type aggregate_module :: module
  # user shared assigns
  @type assigns :: %{atom => any}
  # id with which command correlates
  @type correlation_id :: String.t() | nil
  # command name, could be struct name or atom
  @type command :: atom
  # single event generated by aggregate
  @type event :: struct()
  # events generated by command execution
  @type events :: nil | event | [event]
  # indicates that processing pipeline halted and none of other plugs that waiths for execution will be excuted
  @type halted :: boolean
  # pit to which reposponse should be reply-ed
  @type owner :: pid
  # command parameters
  @type params :: map | struct
  # server that executes command in given context
  @type peer :: pid
  # plug that can be registered into command pipeline
  @type plug :: module | atom
  # plugin private assigns
  @type private :: map
  # status of current context
  @type status :: :init | :executing | :success | :commiting | :commited | :failed

  @type t :: %Context{
          aggregate: struct,
          aggregate_module: aggregate_module,
          assigns: assigns,
          causation_id: term,
          correlation_id: correlation_id,
          command: command,
          events: events,
          halted: halted,
          owner: owner,
          params: params,
          peer: peer,
          private: private,
          retry: integer,
          status: status,
          response: any
        }

  defstruct aggregate: nil,
            aggregate_module: nil,
            assigns: %{},
            causation_id: nil,
            correlation_id: nil,
            command: nil,
            events: nil,
            halted: false,
            handler: nil,
            owner: nil,
            params: %{},
            peer: nil,
            private: %{},
            retry: 0,
            status: :init,
            response: nil

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
            causation_id: ctx.causation_id,
            emitted_at: DateTime.utc_now()
          ]
          |> Enum.filter(fn {_, v} -> v != nil end)

        %EventData{
          id: UUID.uuid4(),
          type: Atom.to_string(event.__struct__),
          data: event,
          metadata: Enum.into(metadata, %{})
        }
      end)

    %{ctx | events: events ++ to_emit}
  end

  @spec ok(Context.t(), any()) :: Context.t()
  def ok(%Context{} = ctx, message \\ :ok) do
    unless is_nil(ctx.response) do
      raise RuntimeError, "Response already set!"
    end

    %{ctx | response: message, status: :success}
  end

  @spec error(Context.t(), any()) :: Context.t()
  def error(%Context{} = ctx, reason) do
    %{ctx | halted: true, response: reason, status: :failed}
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

defimpl Collectable, for: Helios.Pipeline.Context do
  def into(data) do
    {data,
     fn data, _ ->
       data
     end}
  end
end