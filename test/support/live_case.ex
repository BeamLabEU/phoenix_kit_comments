defmodule PhoenixKitComments.LiveCase do
  @moduledoc """
  Test case for LiveView tests: wires up the test Endpoint, imports
  `Phoenix.LiveViewTest`, and takes an Ecto SQL sandbox connection.

  Tagged `:integration` automatically, like the rest of the DB-backed suite.

  ## Sandbox ownership is load-bearing here

  Activity rows go through core's `PhoenixKit.Activity.log/3`, which never
  raises: a `DBConnection.OwnershipError` is logged and returned. A LiveView
  runs in its own process, so under a non-shared sandbox every activity
  write from a `render_click` is silently lost
  and an `assert_activity_logged` would pass against code that logs nothing.
  These tests therefore run `async: false`, which makes `Sandbox.start_owner!`
  shared — do not make them async without re-checking that assumption.

  ## Example

      defmodule PhoenixKitComments.Web.ModerationLiveTest do
        use PhoenixKitComments.LiveCase

        test "approving publishes", %{conn: conn} do
          conn = put_test_scope(conn, fake_scope())
          {:ok, view, _html} = live(conn, "/en/admin/comments")
          render_click(view, "approve", %{"uuid" => comment.uuid})
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitComments.Test.Endpoint

      import Ecto.Query, only: [from: 2]
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn
      import PhoenixKitComments.ActivityLogAssertions
      import PhoenixKitComments.DataCase, only: [user_fixture: 0, user_fixture: 1]
      import PhoenixKitComments.LiveCase

      alias PhoenixKitComments.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitComments.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})}
  end

  @doc """
  A real `%PhoenixKit.Users.Auth.Scope{}` for tests.

  Both admin LiveViews gate on `Scope.can_access_admin_area?/1` and
  `Scope.has_module_access?/2`, so the shape matters: `cached_roles` is a
  LIST of role NAMES (`"Owner"`), not atoms and not a MapSet, and
  `cached_permissions` is a MapSet consulted by membership. A plain map for
  the user raises `FunctionClauseError` in `Scope.user_uuid/1`.

  ## Options

    * `:user` — an existing `%User{}` (use `user_fixture/0` when the test
      needs the row to exist, e.g. for `actor_uuid` foreign keys)
    * `:roles` — defaults to `["Owner"]`
    * `:permissions` — defaults to `["comments"]`
  """
  def fake_scope(opts \\ []) do
    user =
      Keyword.get_lazy(opts, :user, fn ->
        %PhoenixKit.Users.Auth.User{
          uuid: Ecto.UUID.generate(),
          email: "moderator-#{System.unique_integer([:positive])}@example.com"
        }
      end)

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: Keyword.get(opts, :authenticated?, true),
      cached_roles: Keyword.get(opts, :roles, ["Owner"]),
      cached_permissions: MapSet.new(Keyword.get(opts, :permissions, ["comments"]))
    }
  end

  @doc "Puts a scope in the session for the `:assign_scope` hook to read."
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
