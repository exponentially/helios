Logger.configure(level: :info)

# defmodule EventstorePort do
#   use GenServer
#   require Logger

#   def stop() do
#     GenServer.call(__MODULE__, :stop)
#   end

#   def start_link(args \\ [], opts \\ []) do
#     GenServer.start_link(__MODULE__, args, Keyword.put(opts, :name, __MODULE__))
#   end

#   def init(args) do
#     command = ["eventstore" | args] |> Enum.join(" ")

#     port =
#       Port.open({:spawn, command}, [
#         :binary,
#         :exit_status
#       ])

#     {:ok, %{latest_output: nil, exit_status: nil, port: port}}
#   end

#   def handle_call(:stop, _, %{port: port} = state) do
#     {:os_pid, pid} = Port.info(port, :os_pid)
#     {_, 0} = System.cmd("kill", ["-9", "#{pid}"], into: IO.stream(:stdio, :line))
#     Port.close(port)
#     {:reply, :ok, state}
#   end

#   # This callback handles data incoming from the command's STDOUT
#   def handle_info({_port, {:data, text_line}}, state) do
#     latest_output = text_line |> String.trim()

#     # Logger.info("Latest output: #{latest_output}")

#     {:noreply, %{state | latest_output: latest_output}}
#   end

#   # This callback tells us when the process exits
#   def handle_info({_port, {:exit_status, status}}, state) do
#     Logger.info("External exit: :exit_status: #{status}")

#     new_state = %{state | exit_status: status}
#     {:noreply, %{state | exit_status: status}}
#   end

#   # no-op catch-all callback for unhandled messages
#   def handle_info(_msg, state), do: {:noreply, state}
# end

# {:ok, _} = EventstorePort.start_link([
#   "--mem-db",
#   "--run-projections=All",
#   "--start-standard-projections=True"
# ])

# Process.sleep(2000)

# ExUnit.after_suite(fn _ ->
#   :ok = EventstorePort.stop()
# end)

ExUnit.start()

alias Helios.EventJournal.Adapter.Eventstore
alias Helios.Integration.TestJournal

eventstore_conn = [
  db_type: :node,
  host: "localhost",
  port: 1113,
  username: "admin",
  password: "changeit",
  reconnect_delay: 2_000,
  connection_name: "helios_test",
  max_attempts: 10
]

Application.put_env(:extreme, :protocol_version, 4)
Application.put_env(:helios, TestJournal, adapter: Eventstore, adapter_config: eventstore_conn)

# Load support files
Code.require_file("../support/journals.exs", __DIR__)
Code.require_file("../support/events.exs", __DIR__)

{:ok, _pid} = TestJournal.start_link()

Process.flag(:trap_exit, true)
