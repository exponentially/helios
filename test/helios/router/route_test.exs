defmodule Helios.Router.RouteTest do
  use ExUnit.Case, async: true

  alias Helios.Router.Route

  @tag :router_route
  test "builds a route based on verb, path, plug, plug options and proxy helper" do
    line = 1
    kind = :match
    verb = :execute
    path = "/users/:id/create_user"
    plug = UserAggregate
    opts = :create_user
    proxy = "users_create_user"
    pipe_through = [:pipeline1, :pipeline2]
    private = %{foo: "bar"}
    assigns = %{bar: "baz"}

    route =
      Route.build(line, kind, verb, path, plug, opts, proxy, pipe_through, private, assigns)

    assert route.kind == kind
    assert route.verb == verb
    assert route.path == path
    assert route.line == line

    assert route.plug == plug
    assert route.opts == opts
    assert route.proxy == proxy
    assert route.pipe_through == pipe_through
    assert route.private == private
    assert route.assigns == assigns
  end

  @tag :router_route
  test "builds expressions based on the route with :id param" do

    route = Route.build(
      1,
      :match,
      :execute,
      "/users/:id/create_user",
      UserAggregate,
      :create_user,
      "users_create_user",
      [:pipeline1, :pipeline2],
      %{foo: "bar"},
      %{bar: "baz"}
    )
    exprs = Route.exprs(route)

    assert exprs.verb_match == :execute
    assert exprs.path == ["users", {:id, [], nil}, "create_user"]
    assert exprs.binding == [{"id", {:id, [], nil}}]
    assert exprs.dispatch == {UserAggregate, :create_user}
  end

  @tag :router_route
  test "builds expressions based on the route without :id param" do

    route = Route.build(
      1,
      :match,
      :execute,
      "/users/create_user",
      UserAggregate,
      :create_user,
      "users_create_user",
      [:pipeline1, :pipeline2],
      %{foo: "bar"},
      %{bar: "baz"}
    )
    exprs = Route.exprs(route)

    assert exprs.verb_match == :execute
    assert exprs.path == ["users", "create_user"]
    assert exprs.binding == []
    assert exprs.dispatch == {UserAggregate, :create_user}
  end
end
