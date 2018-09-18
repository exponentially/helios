defmodule Helios.Integration.Events.UserCreated do
  defstruct [:user_id, :first_name, :last_name]
end

defmodule Helios.Integration.Events.UserEmailChanged do
  defstruct [:user_id, :old_email, :new_email]
end
