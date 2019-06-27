defmodule Helios.Integration.Events do
  defmodule UserCreated do
    defstruct [:user_id, :first_name, :last_name]
  end

  defmodule UserEmailChanged do
    defstruct [:user_id, :old_email, :new_email]
  end
end
