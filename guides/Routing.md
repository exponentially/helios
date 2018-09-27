# Helios Routing

There are two types of processes that messages are touted to. Aggregates should 
receive commands and Subscriptions should receive events and other messages from
outer world but they are pushed to your endpoint.

Below is simple routing module.

```elixir
defmodule MyApp.Router do
  use Helios.Router

  pipeline :secured do
    plug MyApp.Plugs.Authotization
  end

  aggregate "/users", MyApp.Aggregates.UserAggregate, only: [
    :create_user,
    :confirm_email,
    :set_password
  ]

  aggregate "/registrations", MyApp.Aggregates.Registration, only: [
    :create,
    :confirm_email
  ]

  subscribe MyApp.ProcessManagers.UserRegistration, to: [
            {MyApp.Events.UserCreated, :user_id},
            {MyApp.Events.RegistrationStarted, :registration_id},
            {MyApp.Events.EmailConfirmed, :registration_id},
            {MyApp.Events.LoginEnabled, :correlation_id}
            {MyApp.Events.PasswordInitialized, :correlation_id}
          ]
  end

  scope "/", MyApp.Aggregates do
    pipe_through :secured

    aggregate "/users", UserAggregate, only: [
      :reset_password,
      :change_profile
    ]

  end

end
```