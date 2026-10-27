defmodule PhoenixKitComments.Test.Hooks do
  @moduledoc """
  `on_mount` hooks for the LiveView test endpoint.

  Production runs these LiveViews inside core's `live_session
  :phoenix_kit_admin`, which populates `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` from the host's authentication. The test
  endpoint does not load core's hooks, so this replicates the effect from a
  scope the test put in the session via `LiveCase.put_test_scope/2`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKitWeb.Users.Auth

  def on_mount(:assign_scope, _params, session, socket) do
    socket =
      socket
      |> assign(:current_locale, session["phoenix_kit_test_locale"] || "en")
      |> assign(:current_locale_base, session["phoenix_kit_test_locale_base"] || "en")
      |> assign(:url_path, "/en/admin/comments")

    socket =
      case Map.get(session, "phoenix_kit_test_scope") do
        %{user: user} = scope ->
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        _ ->
          socket
      end

    # Core swaps the scope in place when a role's grants change: a halting
    # `handle_info` hook reassigns `:phoenix_kit_current_scope` with no
    # remount and no `handle_params`. `{:test_replace_scope, scope}` does the
    # same, so a test can revoke a key mid-session.
    socket =
      Phoenix.LiveView.attach_hook(socket, :test_scope_refresh, :handle_info, fn
        {:test_replace_scope, scope}, socket ->
          socket =
            socket
            |> assign(:phoenix_kit_current_scope, scope)
            |> assign(:phoenix_kit_current_user, scope.user)

          # Use the same callback dispatcher as core before its hook halts.
          {:halt, Auth.refresh_view_scope_assigns(socket)}

        _other, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
