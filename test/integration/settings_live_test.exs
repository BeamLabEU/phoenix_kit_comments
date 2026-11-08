defmodule PhoenixKitComments.Web.SettingsLiveTest do
  @moduledoc """
  The comments settings page, driven through the real LiveView.

  What the page writes, and to whom it attributes the write: every save goes
  to core's settings history, and that history is only useful if it names
  the person. The module switch, the resource link templates and the reset
  each had a way to undo someone else's change without anyone noticing —
  these tests pin each one down.
  """
  use PhoenixKitComments.LiveCase

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings

  @path "/en/admin/settings/comments"

  setup do
    Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    Settings.update_json_setting("comment_resource_paths", %{})

    admin = user_fixture()
    %{admin: admin, scope: fake_scope(user: admin)}
  end

  defp open(%{conn: conn, scope: scope}) do
    {:ok, view, _html} = live(put_test_scope(conn, scope), @path)
    view
  end

  defp submit_settings(view, settings) do
    view
    |> form("form[phx-submit=save]", %{"settings" => settings})
    |> render_submit()
  end

  defp setting(key), do: Settings.get_setting(key)

  describe "saving" do
    test "writes the form and names the admin in the settings history", ctx do
      view = open(ctx)

      html = submit_settings(view, %{"comments_max_depth" => "7"})

      assert html =~ "Settings saved successfully"
      assert setting("comments_max_depth") == "7"

      # Without the actor every entry read `system`, so nobody could tell who
      # switched comments off or changed the Giphy key.
      assert_activity_logged("setting.changed",
        actor_uuid: ctx.admin.uuid,
        metadata_has: %{"key" => "comments_max_depth", "source" => "settings"}
      )
    end

    test "clamps numbers into their range", ctx do
      view = open(ctx)

      submit_settings(view, %{"comments_max_length" => "5000000", "comments_max_depth" => "0"})

      assert setting("comments_max_length") == "100000"
      assert setting("comments_max_depth") == "1"
    end

    test "stores only the allowed values of the rating and the switches", ctx do
      Settings.update_setting("comments_giphy_rating", "pg")
      view = open(ctx)

      render_hook(view, "save", %{
        "settings" => %{"comments_giphy_rating" => "nc-17", "comments_moderation" => "yes"}
      })

      assert setting("comments_giphy_rating") == "pg"
      refute setting("comments_moderation") == "yes"
    end

    test "ignores a value that is not a string instead of crashing", ctx do
      Settings.update_setting("comments_max_depth", "10")
      view = open(ctx)

      # `to_string/1` on a map raised before the save's own rescue.
      render_hook(view, "save", %{"settings" => %{"comments_max_depth" => %{"x" => "1"}}})

      assert render(view) =~ "Save Settings"
      assert setting("comments_max_depth") == "10"
    end
  end

  describe "the module switch" do
    test "a page opened before comments were switched off does not switch them back on", ctx do
      view = open(ctx)

      # The Owner switches comments off elsewhere (the Modules page).
      Settings.update_boolean_setting_with_module("comments_enabled", false, "comments")

      # This page still shows the switch ON; saving its limits re-posted it.
      submit_settings(view, %{"comments_max_depth" => "8"})

      assert setting("comments_max_depth") == "8"
      assert setting("comments_enabled") == "false"
    end

    test "switching off from here is written with the actor and announced", ctx do
      Events.subscribe_to_modules()
      view = open(ctx)

      submit_settings(view, %{"comments_enabled" => "false"})

      assert setting("comments_enabled") == "false"
      assert_receive {:module_disabled, "comments"}

      assert_activity_logged("setting.changed",
        actor_uuid: ctx.admin.uuid,
        metadata_has: %{"key" => "comments_enabled", "source" => "settings"}
      )
    end
  end

  describe "reset" do
    test "puts the options back but leaves the switch and the Giphy key alone", ctx do
      Settings.update_setting("comments_giphy_api_key", "the-key")
      Settings.update_setting("comments_max_depth", "33")
      Settings.update_boolean_setting_with_module("comments_moderation", true, "comments")
      view = open(ctx)

      html = render_click(view, "reset_defaults", %{})

      assert html =~ "Settings reset to defaults"
      assert setting("comments_max_depth") == "10"
      assert setting("comments_moderation") == "false"
      # Reset used to turn comments OFF and erase the key, under a confirm
      # that spoke only of "moderation, limits, Giphy and attachment options".
      assert setting("comments_enabled") == "true"
      assert setting("comments_giphy_api_key") == "the-key"
    end
  end

  describe "resource link templates" do
    defp templates, do: PhoenixKitComments.get_resource_path_templates()

    defp add_template(view, type, path) do
      render_hook(view, "add_resource_path", %{
        "resource_path" => %{"resource_type" => type, "path_template" => path}
      })
    end

    test "adding one keeps a template added elsewhere since the page loaded", ctx do
      view = open(ctx)

      # Another admin, in another tab.
      Settings.update_json_setting("comment_resource_paths", %{
        "hats" => %{"path" => "/hats/:uuid"}
      })

      html = add_template(view, "shoes", "/shoes/:uuid")

      assert html =~ ~s(Added path for &quot;shoes&quot;)
      assert %{"hats" => _, "shoes" => %{"path" => "/shoes/:uuid"}} = templates()
    end

    test "removing one keeps a template added elsewhere since the page loaded", ctx do
      Settings.update_json_setting("comment_resource_paths", %{
        "shoes" => %{"path" => "/shoes/:uuid"}
      })

      view = open(ctx)

      Settings.update_json_setting("comment_resource_paths", %{
        "shoes" => %{"path" => "/shoes/:uuid"},
        "hats" => %{"path" => "/hats/:uuid"}
      })

      render_click(view, "remove_resource_path", %{"type" => "shoes"})

      assert Map.keys(templates()) == ["hats"]
    end

    test "names the admin in the settings history", ctx do
      view = open(ctx)

      add_template(view, "shoes", "/shoes/:uuid")

      assert_activity_logged("setting.changed",
        actor_uuid: ctx.admin.uuid,
        metadata_has: %{"key" => "comment_resource_paths", "source" => "settings"}
      )
    end

    test "refuses a template that leaves the site", ctx do
      view = open(ctx)

      # Protocol-relative: `"://"` was the only guard, so this passed and
      # rendered as an off-site link on the moderation page.
      assert add_template(view, "a", "//evil.example/:uuid") =~ "must be a relative path"
      # With a root prefix `:prefix` is "", leaving a `javascript:` href that
      # `<.link>` refused to render — the moderation page crashed instead.
      assert add_template(view, "b", ":prefixjavascript:alert(1)//:uuid") =~
               "must be a relative path"

      # A control character (the edit form is a textarea).
      assert add_template(view, "c", "/x\n/:uuid") =~ "must be a relative path"
      assert templates() == %{}
    end

    test "accepts an ordinary path and a prefixed one", ctx do
      view = open(ctx)

      add_template(view, "shoes", "/order/shoes/:uuid")
      add_template(view, "hats", ":prefix/admin/hats/:metadata.slug")

      assert %{"shoes" => _, "hats" => _} = templates()
    end

    test "saving an edit with no edit open writes nothing", ctx do
      view = open(ctx)

      # Wrote the template under a `nil` key and flashed `Updated path for ""`.
      render_hook(view, "save_resource_path", %{
        "resource_path" => %{"path_template" => "/x/:uuid"}
      })

      assert templates() == %{}
    end

    test "events with a missing or malformed key are ignored", ctx do
      view = open(ctx)

      render_hook(view, "remove_resource_path", %{})
      render_hook(view, "edit_resource_path", %{"type" => %{"x" => "1"}})
      render_hook(view, "add_resource_path", %{"resource_path" => "shoes"})
      render_hook(view, "live_draft_path", %{"resource_path" => %{"path_template" => ["x"]}})
      render_hook(view, "switch_settings_tab", %{"tab" => "nonsense"})

      assert render(view) =~ "Save Settings"
    end

    test "does not ask for a template where a resource handler links already", ctx do
      author = user_fixture()

      {:ok, _} =
        PhoenixKitComments.create_comment("user", Ecto.UUID.generate(), author.uuid, %{
          content: "about a user"
        })

      {:ok, _} =
        PhoenixKitComments.create_comment("orphan_thing", Ecto.UUID.generate(), author.uuid, %{
          content: "about nothing known"
        })

      view = open(ctx)

      # Core asks the handler before any template, so a template for `user`
      # would never be used.
      assert has_element?(view, "#draft-path-orphan_thing")
      refute has_element?(view, "#draft-path-user")
    end
  end
end
