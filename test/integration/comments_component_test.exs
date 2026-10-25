defmodule PhoenixKitComments.Web.CommentsComponentTest do
  @moduledoc """
  The embedded component, driven through a real host page.

  Everything here was found by review rather than by a test, because the
  component had no host to be driven from. Each test states the behaviour a
  host depends on, not the implementation that currently provides it.
  """
  use PhoenixKitComments.LiveCase

  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.Web.CommentsComponent

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")

    on_exit(fn ->
      PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    end)

    user = user_fixture()

    %{user: user, scope: fake_scope(user: user), resource_uuid: Ecto.UUID.generate()}
  end

  defp host_path(resource_uuid, opts \\ []) do
    case Keyword.get(opts, :decoration_keys) do
      nil -> "/en/test/thread/#{resource_uuid}"
      keys -> "/en/test/thread/#{resource_uuid}?decoration_keys=#{Enum.join(keys, ",")}"
    end
  end

  defp comments_for(resource_uuid) do
    PhoenixKitComments.list_comments("test_resource", resource_uuid)
  end

  # The composer is rendered behind the "Write comment" button, so every
  # posting test has to open it the way a person does.
  defp post_comment(view, params) do
    # Clicked through the ELEMENT, not `render_click(view, ...)`: these are
    # the component's events, and only the element carries the `phx-target`
    # that routes them there.
    view |> element("button[phx-click='open_composer']") |> render_click()

    view
    |> element("form[phx-submit='add_comment']")
    |> render_submit(params)
  end

  describe "the module kill switch" do
    test "an explicit enabled host attr still respects the module switch",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))
      Phoenix.LiveView.send_update(view.pid, CommentsComponent, id: "test-thread", enabled: true)
      render(view)

      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_enabled",
        false,
        "comments"
      )

      post_comment(view, %{"comment" => "after the switch"})

      assert comments_for(resource_uuid) == []
    end

    test "stops writes from a thread that was already open when it was flipped",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))

      # Posting works while the module is on.
      post_comment(view, %{"comment" => "before the switch"})

      assert length(comments_for(resource_uuid)) == 1

      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_enabled",
        false,
        "comments"
      )

      # No remount, and no parent re-render either. This is the case the
      # write gate exists for and the one an assign cannot see: a
      # `phx-submit` goes straight to the component's `handle_event`, so
      # `update/2` never runs and `:enabled` still holds whatever it held
      # when the page was rendered. The answer has to be asked at write
      # time, which is why the refusal lives in the create funnel.
      post_comment(view, %{"comment" => "after the switch"})

      assert length(comments_for(resource_uuid)) == 1
    end
  end

  describe "client-supplied metadata" do
    test "cannot claim a decoration link the host declared",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      victim_record = Ecto.UUID.generate()

      {:ok, view, _html} =
        live(
          put_test_scope(conn, scope),
          host_path(resource_uuid, decoration_keys: ["annotation_uuid"])
        )

      post_comment(view, %{
        "comment" => "nice shot",
        "metadata" => %{"annotation_uuid" => victim_record}
      })

      [comment] = comments_for(resource_uuid)

      # The link between a comment and one of the host's records is the
      # host's to make, server-side. A client that can claim it can rename
      # a record it has no rights to, through a `send_update` the host
      # cannot tell from a legitimate one.
      refute Map.has_key?(comment.metadata || %{}, "annotation_uuid")
    end

    test "is dropped even when nothing is decorated yet",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      # The registry is built from data: core's `build_comment_decorations/1`
      # returns `%{}` until an annotation has a title. Keying the drop on the
      # registry alone therefore left the door open on exactly the pages
      # where there was nothing to see yet — and the forged link only
      # surfaces later, once a title appears.
      {:ok, view, _html} =
        live(
          put_test_scope(conn, scope),
          host_path(resource_uuid, decoration_keys: ["annotation_uuid"])
        )

      post_comment(view, %{
        "comment" => "planted",
        "metadata" => %{"annotation_uuid" => Ecto.UUID.generate()}
      })

      [comment] = comments_for(resource_uuid)
      refute Map.has_key?(comment.metadata || %{}, "annotation_uuid")
    end

    test "still carries the host's own extras through", %{
      conn: conn,
      scope: scope,
      resource_uuid: resource_uuid
    } do
      {:ok, view, _html} =
        live(
          put_test_scope(conn, scope),
          host_path(resource_uuid, decoration_keys: ["annotation_uuid"])
        )

      post_comment(view, %{
        "comment" => "with extras",
        "metadata" => %{"box_color" => "#ff5555"}
      })

      [comment] = comments_for(resource_uuid)

      # `:form_extras` is a documented feature. The drop must be surgical:
      # decoration keys only, not "client metadata is untrusted, discard it".
      assert comment.metadata["box_color"] == "#ff5555"
    end
  end

  describe "the audit trail from an embedded thread" do
    test "an edit records who made it", %{
      conn: conn,
      scope: scope,
      user: user,
      resource_uuid: resource_uuid
    } do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", resource_uuid, user.uuid, %{
          content: "original"
        })

      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))

      view
      |> element("button[phx-click='edit_comment'][phx-value-id='#{comment.uuid}']")
      |> render_click()

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => "edited"})

      assert Repo.get!(Comment, comment.uuid).content == "edited"

      # The admin page has always passed the actor through; this path — the
      # one ordinary users take — logged "a comment was edited" with nobody
      # attached, which is the one question an audit row is asked.
      assert_activity_logged("comments.comment_updated",
        resource_uuid: comment.uuid,
        actor_uuid: user.uuid
      )
    end

    test "a delete records who made it", %{
      conn: conn,
      scope: scope,
      user: user,
      resource_uuid: resource_uuid
    } do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", resource_uuid, user.uuid, %{
          content: "to be deleted"
        })

      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))

      view
      |> element("button[phx-click='delete_comment'][phx-value-id='#{comment.uuid}']")
      |> render_click()

      assert Repo.get!(Comment, comment.uuid).status == "deleted"

      assert_activity_logged("comments.comment_deleted",
        resource_uuid: comment.uuid,
        actor_uuid: user.uuid
      )
    end
  end

  # Socket-level on purpose. The picker never renders for a logged-out
  # viewer, so the host page cannot show the difference between "refused"
  # and "searched" — and letting the unguarded path run would put a real
  # request to api.giphy.com in the suite, which is the very thing being
  # prevented.
  defp anonymous_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        # The host said nothing, so the module's own switch decides; it is
        # on for this suite.
        host_enabled: nil,
        can_post?: false,
        giphy_query: "",
        giphy_searching?: false
      }
    }
  end

  describe "the giphy picker" do
    test "a logged-out viewer cannot spend the host's Giphy quota" do
      assert {:noreply, socket} =
               CommentsComponent.handle_event(
                 "giphy_search",
                 %{"value" => "cats"},
                 anonymous_socket()
               )

      # Nothing started: no query recorded, no in-flight flag. The markup is
      # not the control — the component's cid is addressable by anyone who
      # can see the page, so an anonymous visitor could drive outbound calls
      # with query strings of their choosing against the host's quota.
      assert socket.assigns.giphy_query == ""
      refute socket.assigns.giphy_searching?
    end
  end

  describe "malformed payloads" do
    test "a non-binary edit body does not kill the host LiveView",
         %{conn: conn, scope: scope, user: user, resource_uuid: resource_uuid} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", resource_uuid, user.uuid, %{
          content: "original"
        })

      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))

      view
      |> element("button[phx-click='edit_comment'][phx-value-id='#{comment.uuid}']")
      |> render_click()

      # `content[x]=y` arrives as a map. The create path was hardened against
      # exactly this shape; the edit path reached String.trim/1 with it.
      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => %{"x" => "y"}})

      assert Repo.get!(Comment, comment.uuid).content == "original"
      assert render(view) =~ "original"
    end
  end
end
