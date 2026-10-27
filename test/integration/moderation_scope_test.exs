defmodule PhoenixKitComments.Web.ModerationScopeTest do
  @moduledoc """
  Who sees and acts on what on the moderation page.

  The base `comments` key means "moderate comments on records you manage":
  each resource handler's `moderatable_resources/2` answers which, and a type
  whose handler does not answer is invisible (fail closed — no exception for
  handler-less types, for `"user"`, or for the viewer's own comments).
  `comments.moderate_all` sees everything, as the base key used to.

  Every crafted-uuid test sends an event the page would never offer for that
  row — the row is not on the page — because that is the attack: the
  rendered list being right says nothing about the handlers.
  """
  use PhoenixKitComments.LiveCase

  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.Web.CommentsComponent

  @path "/en/admin/comments"
  @settings_path "/en/admin/settings/comments"

  # The answers live in app env, not in the handler: the LiveView runs in
  # another process, and each test decides what the handler says.
  defmodule ScopedHandler do
    @moduledoc false
    @behaviour PhoenixKitComments.ResourceHandler

    @impl true
    def moderatable_resources(type, _scope) do
      :phoenix_kit_comments |> Application.get_env(:test_moderatable, %{}) |> Map.get(type, [])
    end
  end

  defmodule NoCallbackHandler do
    @moduledoc false
    @behaviour PhoenixKitComments.ResourceHandler

    @impl true
    def on_comment_created(_type, _uuid, _comment), do: :ok
  end

  defmodule RaisingHandler do
    @moduledoc false
    def moderatable_resources(_type, _scope), do: raise("handler bug")
  end

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")

    previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)

    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{
      "scoped_thing" => ScopedHandler,
      "whole_type" => ScopedHandler,
      "plain_thing" => NoCallbackHandler,
      "raising_thing" => RaisingHandler,
      "user" => NoCallbackHandler
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)

      Application.delete_env(:phoenix_kit_comments, :test_moderatable)
    end)

    author = user_fixture(%{first_name: "Ada", last_name: "Author"})
    moderator = user_fixture()

    managed = Ecto.UUID.generate()
    unmanaged = Ecto.UUID.generate()

    Application.put_env(:phoenix_kit_comments, :test_moderatable, %{
      "scoped_thing" => [managed],
      "whole_type" => :all
    })

    c = fn type, uuid, content, extra ->
      {:ok, comment} =
        PhoenixKitComments.create_comment(
          type,
          uuid,
          author.uuid,
          Map.merge(%{content: content, status: "pending"}, extra)
        )

      comment
    end

    visible = c.("scoped_thing", managed, "visible managed comment", %{})
    whole = c.("whole_type", Ecto.UUID.generate(), "visible whole-type comment", %{})
    other_record = c.("scoped_thing", unmanaged, "hidden other record", %{})
    no_callback = c.("plain_thing", Ecto.UUID.generate(), "hidden no callback", %{})
    no_handler = c.("orphan_thing", Ecto.UUID.generate(), "hidden no handler", %{})
    raising = c.("raising_thing", Ecto.UUID.generate(), "hidden raising handler", %{})
    profile = c.("user", Ecto.UUID.generate(), "hidden user profile", %{})

    # A reply on a managed record whose parent sits on an unmanaged one: the
    # schema only checks the parent FK, never that both share a resource.
    secret_parent = c.("scoped_thing", unmanaged, "SECRETPARENTTEXT", %{})

    reply =
      c.("scoped_thing", managed, "visible reply", %{parent_uuid: secret_parent.uuid})

    %{
      author: author,
      moderator: moderator,
      managed: managed,
      in_scope: [visible, whole, reply],
      out_of_scope: [other_record, no_callback, no_handler, raising, profile, secret_parent],
      visible: visible,
      reply: reply,
      other_record: other_record,
      no_handler: no_handler,
      base_scope: fake_scope(user: moderator, roles: ["Editor"], permissions: ["comments"]),
      all_scope:
        fake_scope(
          user: moderator,
          roles: ["Editor"],
          permissions: ["comments", "comments.moderate_all"]
        )
    }
  end

  defp status_of(comment), do: Repo.get!(Comment, comment.uuid).status

  defp open(conn, scope), do: live(put_test_scope(conn, scope), @path)

  describe "a base-key holder" do
    @tag :capture_log
    test "sees only comments on records a handler says they manage", ctx do
      {:ok, _view, html} = open(ctx.conn, ctx.base_scope)

      for comment <- ctx.in_scope, do: assert(html =~ comment.content)

      # The raising handler is caught and counts as none.
      for comment <- ctx.out_of_scope,
          do: refute(html =~ comment.content, "leaked: #{comment.content}")

      # The count is of what the viewer may see, not of the site.
      assert html =~ "3 comments"
    end

    @tag :capture_log
    test "the stats and the type filter come from the same rule", ctx do
      rule = PhoenixKitComments.moderation_scope(ctx.base_scope)

      assert PhoenixKitComments.comment_stats(rule).total == 3
      assert PhoenixKitComments.comment_stats(rule).pending == 3
      assert PhoenixKitComments.list_resource_types(rule) == ["scoped_thing", "whole_type"]

      {:ok, _view, html} = open(ctx.conn, ctx.base_scope)
      refute html =~ ~s(value="orphan_thing")
      refute html =~ ~s(value="plain_thing")
    end

    @tag :capture_log
    test "a handler without the callback, or no handler at all, shows nothing", ctx do
      Application.put_env(:phoenix_kit_comments, :test_moderatable, %{})

      {:ok, _view, html} = open(ctx.conn, ctx.base_scope)

      refute html =~ "visible managed comment"
      refute html =~ "hidden no handler"
      assert html =~ "No comments found"
      assert html =~ "This page shows comments on records you manage."
    end

    @tag :capture_log
    test "sees no author emails, only the name the public thread shows", ctx do
      {:ok, _view, html} = open(ctx.conn, ctx.base_scope)

      refute html =~ ctx.author.email
      assert html =~ "Ada Author"
    end

    @tag :capture_log
    test "a reply's out-of-scope parent is not quoted", ctx do
      {:ok, _view, html} = open(ctx.conn, ctx.base_scope)

      assert html =~ "visible reply"
      refute html =~ "SECRETPARENTTEXT"
      refute html =~ "SECRETPARENT"
    end

    @tag :capture_log
    test "cannot open a crafted out-of-scope comment in the modal", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)

      html = render_click(view, "view_comment", %{"uuid" => ctx.other_record.uuid})
      refute html =~ "hidden other record"

      html = render_click(view, "view_comment", %{"uuid" => ctx.visible.uuid})
      assert html =~ "modal-open"
    end

    @tag :capture_log
    test "cannot approve, hide, delete or restore a crafted out-of-scope uuid", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)
      target = ctx.other_record

      for event <- ~w(approve hide delete) do
        html = render_click(view, event, %{"uuid" => target.uuid})
        assert html =~ "Comment not found", "#{event} was not refused"
        assert status_of(target) == "pending"
      end

      Repo.update_all(from(c in Comment, where: c.uuid == ^target.uuid),
        set: [status: "deleted"]
      )

      html = render_click(view, "restore", %{"uuid" => target.uuid})
      assert html =~ "Comment not found"
      assert status_of(target) == "deleted"
    end

    @tag :capture_log
    test "bulk actions touch only the in-scope rows of a crafted selection", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)
      out = Enum.map(ctx.out_of_scope, & &1.uuid)

      render_click(view, "bulk_approve", %{"uuids" => [ctx.visible.uuid | out]})
      assert status_of(ctx.visible) == "published"
      for c <- ctx.out_of_scope, do: assert(status_of(c) == "pending")

      render_click(view, "bulk_hide", %{"uuids" => out})
      for c <- ctx.out_of_scope, do: assert(status_of(c) == "pending")

      render_click(view, "bulk_delete_comments", %{"uuids" => out})
      for c <- ctx.out_of_scope, do: assert(status_of(c) == "pending")
    end

    @tag :capture_log
    test "can act on an in-scope comment", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)

      html = render_click(view, "approve", %{"uuid" => ctx.visible.uuid})

      assert html =~ "Comment approved"
      assert status_of(ctx.visible) == "published"
    end

    @tag :capture_log
    test "does not get the settings shortcut", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)
      refute has_element?(view, "#comments-actions-tile")
    end

    @tag :capture_log
    test "a revoked record stops working on the next click, not the next page load", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)
      Application.put_env(:phoenix_kit_comments, :test_moderatable, %{})

      html = render_click(view, "approve", %{"uuid" => ctx.visible.uuid})

      assert html =~ "Comment not found"
      assert status_of(ctx.visible) == "pending"
    end
  end

  describe "a comments.moderate_all holder" do
    @tag :capture_log
    test "sees every comment and the authors' emails", ctx do
      {:ok, _view, html} = open(ctx.conn, ctx.all_scope)

      for comment <- ctx.in_scope ++ ctx.out_of_scope, do: assert(html =~ comment.content)
      assert html =~ ctx.author.email
    end

    test "acts on a comment no handler knows", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.all_scope)

      render_click(view, "approve", %{"uuid" => ctx.no_handler.uuid})

      assert status_of(ctx.no_handler) == "published"
    end
  end

  describe "the settings page" do
    test "refuses a base-key holder", ctx do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(put_test_scope(ctx.conn, ctx.base_scope), @settings_path)

      assert to =~ "/admin"
      assert flash["error"] =~ "do not have access"
    end

    test "refuses a comments.moderate_all holder without comments.settings", ctx do
      assert {:error, {:live_redirect, _}} =
               live(put_test_scope(ctx.conn, ctx.all_scope), @settings_path)
    end

    test "opens for a comments.settings holder, even with the module off", ctx do
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_enabled",
        false,
        "comments"
      )

      scope =
        fake_scope(
          user: ctx.moderator,
          roles: ["Editor"],
          permissions: ["comments", "comments.settings"]
        )

      assert {:ok, _view, _html} = live(put_test_scope(ctx.conn, scope), @settings_path)
    end

    test "the settings shortcut shows for a comments.settings holder", ctx do
      scope =
        fake_scope(
          user: ctx.moderator,
          roles: ["Editor"],
          permissions: ["comments", "comments.settings"]
        )

      {:ok, view, _html} = open(ctx.conn, scope)
      assert has_element?(view, "#comments-actions-tile")
    end
  end

  describe "an emailed moderator whose moderate_all is revoked mid-session" do
    @tag :capture_log
    test "reloads the list, counts and filters and closes an out-of-scope modal", ctx do
      scope = %{
        ctx.all_scope
        | cached_permissions: MapSet.put(ctx.all_scope.cached_permissions, "comments.settings")
      }

      {:ok, view, _html} = open(ctx.conn, scope)
      assert has_element?(view, "#comments-actions-tile")
      render_click(view, "view_comment", %{"uuid" => ctx.other_record.uuid})
      assert has_element?(view, ".modal-open")

      send(view.pid, {:test_replace_scope, ctx.base_scope})
      html = render(view)

      for comment <- ctx.in_scope, do: assert(html =~ comment.content)
      for comment <- ctx.out_of_scope, do: refute(html =~ comment.content)
      assert html =~ "3 comments"
      assert has_element?(view, ".stat-value.text-primary", "3")
      refute html =~ ~s(value="orphan_thing")
      refute has_element?(view, ".modal-open")
      refute has_element?(view, "#comments-actions-tile")
    end

    @tag :capture_log
    test "a newly granted moderate_all refreshes the visible records", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.base_scope)

      send(view.pid, {:test_replace_scope, ctx.all_scope})
      html = render(view)

      for comment <- ctx.in_scope ++ ctx.out_of_scope, do: assert(html =~ comment.content)
      assert html =~ ctx.author.email
    end

    @tag :capture_log
    test "losing the base key clears the dashboard before core evicts the page", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.all_scope)
      revoked = fake_scope(user: ctx.moderator, roles: ["Editor"], permissions: [])

      send(view.pid, {:test_replace_scope, revoked})
      html = render(view)

      for comment <- ctx.in_scope ++ ctx.out_of_scope, do: refute(html =~ comment.content)
      assert has_element?(view, ".stat-value.text-primary", "0")
      assert html =~ "No comments found"
    end

    @tag :capture_log
    test "stops seeing emails in the list and in the modal opened afterwards", ctx do
      {:ok, view, html} = open(ctx.conn, ctx.all_scope)
      assert html =~ ctx.author.email

      # What core does when a role's grants change: the scope is swapped in
      # place, with no remount and no handle_params.
      send(view.pid, {:test_replace_scope, ctx.base_scope})

      refute render(view) =~ ctx.author.email

      html = render_click(view, "view_comment", %{"uuid" => ctx.visible.uuid})
      assert html =~ "modal-open"
      refute html =~ ctx.author.email
    end
  end

  describe "deleting from the embedded thread" do
    # The host page comments on "test_resource" records.
    setup ctx do
      handlers = Application.get_env(:phoenix_kit, :comment_resource_handlers)

      Application.put_env(
        :phoenix_kit,
        :comment_resource_handlers,
        Map.put(handlers, "test_resource", ScopedHandler)
      )

      record = Ecto.UUID.generate()

      {:ok, theirs} =
        PhoenixKitComments.create_comment("test_resource", record, ctx.author.uuid, %{
          content: "someone else's comment",
          status: "published"
        })

      # An Admin by ROLE — which used to be enough to delete anyone's comment.
      {:ok, _} = Roles.assign_role(ctx.moderator, "Admin")

      %{record: record, theirs: theirs}
    end

    defp thread(conn, scope, record),
      do: live(put_test_scope(conn, scope), "/en/test/thread/#{record}")

    defp crafted_delete(view, uuid) do
      view
      |> with_target("[data-phx-component]")
      |> render_click("delete_comment", %{"id" => uuid})
    end

    @tag :capture_log
    test "the Admin role alone no longer deletes someone else's comment", ctx do
      {:ok, view, _html} = thread(ctx.conn, ctx.base_scope, ctx.record)

      refute has_element?(
               view,
               "button[phx-click='delete_comment'][phx-value-id='#{ctx.theirs.uuid}']"
             )

      crafted_delete(view, ctx.theirs.uuid)
      assert status_of(ctx.theirs) == "published"
    end

    @tag :capture_log
    test "a base-key holder who manages the record may delete it", ctx do
      Application.put_env(:phoenix_kit_comments, :test_moderatable, %{
        "test_resource" => [ctx.record]
      })

      {:ok, view, _html} = thread(ctx.conn, ctx.base_scope, ctx.record)

      view
      |> element("button[phx-click='delete_comment'][phx-value-id='#{ctx.theirs.uuid}']")
      |> render_click()

      assert status_of(ctx.theirs) == "deleted"
    end

    @tag :capture_log
    test "a comments.moderate_all holder may delete it", ctx do
      {:ok, view, _html} = thread(ctx.conn, ctx.all_scope, ctx.record)

      crafted_delete(view, ctx.theirs.uuid)
      assert status_of(ctx.theirs) == "deleted"
    end

    @tag :capture_log
    test "the Admin role alone no longer edits someone else's comment", ctx do
      {:ok, view, _html} = thread(ctx.conn, ctx.base_scope, ctx.record)

      refute has_element?(
               view,
               "button[phx-click='edit_comment'][phx-value-id='#{ctx.theirs.uuid}']"
             )

      view
      |> with_target("[data-phx-component]")
      |> render_click("edit_comment", %{"id" => ctx.theirs.uuid})

      refute has_element?(view, "form[phx-submit='save_edit']")

      view
      |> with_target("[data-phx-component]")
      |> render_submit("save_edit", %{"content" => "rewritten by an admin"})

      assert Repo.get!(Comment, ctx.theirs.uuid).content == "someone else's comment"
    end

    @tag :capture_log
    test "a base-key holder who manages the record may edit it", ctx do
      Application.put_env(:phoenix_kit_comments, :test_moderatable, %{
        "test_resource" => [ctx.record]
      })

      {:ok, view, _html} = thread(ctx.conn, ctx.base_scope, ctx.record)

      view
      |> element("button[phx-click='edit_comment'][phx-value-id='#{ctx.theirs.uuid}']")
      |> render_click()

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => "moderated wording"})

      assert Repo.get!(Comment, ctx.theirs.uuid).content == "moderated wording"
    end

    @tag :capture_log
    test "a host that passes no scope: a moderate_all revoked mid-session stops the next write",
         ctx do
      # The scope comes from the DATABASE here, as on a CRM or projects page:
      # a real role holding the keys, assigned to the viewer.
      {:ok, role} = Roles.create_role(%{name: "Mods #{System.unique_integer([:positive])}"})
      viewer = user_fixture()
      {:ok, _} = Roles.assign_role(viewer, role.name)
      {:ok, _} = Permissions.grant_permission(role.uuid, "comments", nil)

      {:ok, _} =
        Permissions.grant_permission(role.uuid, "comments.moderate_all", nil)

      {:ok, other} =
        PhoenixKitComments.create_comment("test_resource", ctx.record, ctx.author.uuid, %{
          content: "second comment",
          status: "published"
        })

      scope = fake_scope(user: viewer, roles: [], permissions: [])

      # Plain textarea: with Leaf on, the edit form holds a second component
      # and a crafted event cannot be aimed at this one alone.
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_rich_text",
        false,
        "comments"
      )

      {:ok, view, _html} =
        live(put_test_scope(ctx.conn, scope), "/en/test/thread/#{ctx.record}?no_scope=1")

      # Allowed while the role holds moderate_all: open an edit on one.
      view
      |> element("button[phx-click='edit_comment'][phx-value-id='#{other.uuid}']")
      |> render_click()

      assert has_element?(view, "form[phx-submit='save_edit']")

      :ok = Permissions.revoke_permission(role.uuid, "comments.moderate_all")

      crafted_delete(view, ctx.theirs.uuid)
      assert status_of(ctx.theirs) == "published"

      view
      |> with_target("[data-phx-component]")
      |> render_submit("save_edit", %{"content" => "after revocation"})

      assert Repo.get!(Comment, other.uuid).content == "second comment"

      # An explicit partial update exercises the component's update/2.
      # An unchanged live_component call in a host render can be skipped.
      Phoenix.LiveView.send_update(view.pid, CommentsComponent, id: "test-thread")

      refute has_element?(
               view,
               "button[phx-click='delete_comment'][phx-value-id='#{ctx.theirs.uuid}']"
             )

      refute has_element?(
               view,
               "button[phx-click='edit_comment'][phx-value-id='#{ctx.theirs.uuid}']"
             )

      {:ok, _} = Permissions.grant_permission(role.uuid, "comments.moderate_all", nil)
      Phoenix.LiveView.send_update(view.pid, CommentsComponent, id: "test-thread")

      assert has_element?(
               view,
               "button[phx-click='delete_comment'][phx-value-id='#{ctx.theirs.uuid}']"
             )
    end

    @tag :capture_log
    test "the author still deletes their own without any comments key", ctx do
      scope = fake_scope(user: ctx.author, roles: [], permissions: [])
      {:ok, view, _html} = thread(ctx.conn, scope, ctx.record)

      view
      |> element("button[phx-click='delete_comment'][phx-value-id='#{ctx.theirs.uuid}']")
      |> render_click()

      assert status_of(ctx.theirs) == "deleted"
    end
  end
end
