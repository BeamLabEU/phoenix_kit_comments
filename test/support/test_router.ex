defmodule PhoenixKitComments.Test.Router do
  @moduledoc """
  Minimal router for the LiveView test suite. Routes mirror the URLs the
  comments admin LiveViews push themselves to, so `live/2` works with the
  production URL shape.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable, and admin paths always carry
  the default locale prefix — so the base is `/en/admin/comments`. The
  `/phoenix_kit/...` routes mirror it because `push_patch` prepends
  whatever prefix IS configured; without them, a filter or search event
  crashes with "cannot invoke handle_params nor navigate/patch to ...".
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitComments.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  # Full paths in one live_session: a `push_patch` reaches only a route of
  # the same LiveView in the SAME live_session. The filter and search events
  # patch to `Routes.path("/admin/comments?…")`, which in an event handler
  # resolves without the locale (`/phoenix_kit/admin/comments`), so that
  # path sits beside the one the tests mount.
  scope "/", PhoenixKitComments.Web do
    pipe_through(:browser)

    live_session :comments_test,
      layout: {PhoenixKitComments.Test.Layouts, :app},
      on_mount: {PhoenixKitComments.Test.Hooks, :assign_scope} do
      live("/en/admin/comments", Index, :index, as: :comments)
      live("/en/admin/settings/comments", Settings, :index, as: :comments_settings)
      live("/phoenix_kit/admin/comments", Index, :index, as: :comments_patched)
    end
  end

  scope "/phoenix_kit/en/admin", PhoenixKitComments.Web do
    pipe_through(:browser)

    live_session :comments_test_pk_prefix,
      layout: {PhoenixKitComments.Test.Layouts, :app},
      on_mount: {PhoenixKitComments.Test.Hooks, :assign_scope} do
      live("/comments", Index, :index, as: :comments_pk)
      live("/settings/comments", Settings, :index, as: :comments_settings_pk)
    end
  end

  # A consuming application's page, embedding the component. See
  # `PhoenixKitComments.Test.HostLive` for why the admin routes above cannot
  # stand in for it.
  scope "/en/test", PhoenixKitComments.Test do
    pipe_through(:browser)

    live_session :comments_test_host,
      layout: {PhoenixKitComments.Test.Layouts, :app},
      on_mount: {PhoenixKitComments.Test.Hooks, :assign_scope} do
      live("/thread/:resource_uuid", HostLive, :index, as: :test_host)
    end
  end

  # `push_navigate(to: Routes.path("/admin"))` is where both LiveViews send an
  # unauthorized or disabled visitor. Without a route to land on, that
  # redirect raises instead of being assertable.
  scope "/", PhoenixKitComments.Test do
    pipe_through(:browser)
    get("/en/admin", StubController, :index)
    get("/phoenix_kit/en/admin", StubController, :index)
  end
end

defmodule PhoenixKitComments.Test.StubController do
  @moduledoc """
  Landing point for the admin redirect the LiveViews perform when access is
  refused or the module is disabled. Exists so those redirects are assertable
  rather than raising a routing error.
  """
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params), do: Phoenix.Controller.text(conn, "admin")
end
