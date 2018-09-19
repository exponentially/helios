ExUnit.start()

Application.put_env(
  :helios,
  Helios.Integration.TestJournal,
  adapter: Helios.EventJournal.Adapter.Memory,
  adapter_config: []
)

Code.require_file("../../integration_test/support/events.exs", __DIR__)
Code.require_file("../../integration_test/support/aggregates.exs", __DIR__)
Code.require_file("../../integration_test/support/assertions.exs", __DIR__)
Code.require_file("../../integration_test/support/journals.exs", __DIR__)

{:ok, _} = Helios.Integration.TestJournal.start_link()
#Application.get_env(:helios, :default_journal)
