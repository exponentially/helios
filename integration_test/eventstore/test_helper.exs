Logger.configure(level: :info)
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
