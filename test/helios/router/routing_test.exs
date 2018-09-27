defmodule Helios.RoutingTest do
  use ExUnit.Case, async: true

  defmodule MyRouter do
    use Helios.Router

    scope "/", Helios.Integration do
      aggregate "/users", UserAggregate, only: [:create_user]
    end
  end


  test "should" do

  end
end
