Code.require_file("router_helper.exs", "test/support")

defmodule Helios.RoutingTest.MyRouter do
  use Helios.Router
  require Logger

  pipeline :test do
    plug :log_hello
  end

  scope "/", Helios.Integration do
    pipe_through(:test)
    aggregate("/users", UserAggregate, only: [:create_user])
  end

  def log_hello(ctx, _) do
    Logger.info("hello")
    ctx
  end
end



defmodule Helios.RoutingTest do
  use ExUnit.Case, async: true
  alias Helios.RoutingTest.MyRouter


  test "should" do
    params = %{
      "id" => 1,
      "first_name" => "Jhon",
      "last_name" => "Doe",
      "email" => "jhon.doe@gmail.com"
    }

  end
end
