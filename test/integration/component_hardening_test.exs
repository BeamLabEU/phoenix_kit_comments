defmodule PhoenixKitComments.ComponentHardeningTest.Recorder do
  @moduledoc false
  # Stands in for the host component that owns a decorated record: it
  # receives the decoration edit and reports it to the test.
  use Phoenix.LiveComponent

  @impl true
  def render(assigns), do: ~H"<div id={@id}></div>"

  @impl true
  def update(%{action: _} = update, socket) do
    send(socket.assigns.test_pid, {:decoration_update, Map.drop(update, [:id])})
    {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}
end

defmodule PhoenixKitComments.ComponentHardeningTest.Host do
  @moduledoc false
  use Phoenix.LiveView

  alias PhoenixKitComments.ComponentHardeningTest.Recorder
  alias PhoenixKitComments.Web.CommentsComponent

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       user: session["user"],
       scope: session["scope"],
       resource_uuid: session["resource_uuid"],
       composer_position: Map.get(session, "composer_position", :top),
       decorations: Map.get(session, "decorations", %{}),
       test_pid: session["test_pid"]
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="isolated-host">
      <.live_component module={Recorder} id="recorder" test_pid={@test_pid} />
      <.live_component
        module={CommentsComponent}
        id="hardening-thread"
        resource_type="test_resource"
        resource_uuid={@resource_uuid}
        current_user={@user}
        pk_scope={@scope}
        composer_position={@composer_position}
        comment_decorations={@decorations}
        decoration_keys={Map.keys(@decorations)}
        parent_module={Recorder}
        parent_id="recorder"
      />
    </div>
    """
  end

  @impl true
  def handle_event("switch_resource", %{"uuid" => uuid}, socket),
    do: {:noreply, assign(socket, :resource_uuid, uuid)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}
end

defmodule PhoenixKitComments.ComponentHardeningTest do
  @moduledoc """
  The embedded thread against the states and payloads a real page meets:
  a comment deleted or hidden in another tab while this one still shows it,
  a refused staged file, a reply box opened before its parent went away, a
  host that points one component at another record, a read-only preview, and
  events that arrive with keys missing.

  Every case here was a crash of the HOST LiveView (a LiveComponent that
  raises takes its page with it) or a write the person was told succeeded.

  Most run in `Test.HostLive`. The ones that need what that page does not
  offer — decorations with a parent that records the `send_update`, a
  read-only `composer_position: nil`, a host switching records — mount
  `Host` above with `live_isolated/3`.
  """
  use PhoenixKitComments.LiveCase

  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.ComponentHardeningTest.Host

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")

    on_exit(fn ->
      PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    end)

    user = user_fixture()
    %{user: user, scope: fake_scope(user: user), r: Ecto.UUID.generate()}
  end

  defp host_path(r), do: "/en/test/thread/#{r}"

  defp mount_host(conn, scope, r), do: live(put_test_scope(conn, scope), host_path(r))

  defp isolated(conn, %{user: user, scope: scope}, session) do
    session =
      Map.merge(
        %{"user" => user, "scope" => scope, "test_pid" => self()},
        session
      )

    live_isolated(conn, Host, session: session)
  end

  defp comment!(user, r, attrs \\ %{}) do
    {:ok, comment} =
      PhoenixKitComments.create_comment(
        "test_resource",
        r,
        user.uuid,
        Map.merge(%{content: "original"}, attrs)
      )

    comment
  end

  defp open_composer(view) do
    view |> element("button[phx-click='open_composer']") |> render_click()
  end

  defp post_comment(view, params) do
    open_composer(view)
    view |> element("form[phx-submit='add_comment']") |> render_submit(params)
  end

  defp open_edit(view, comment) do
    view
    |> element("button[phx-click='edit_comment'][phx-value-id='#{comment.uuid}']")
    |> render_click()
  end

  # The component's root element, which `with_target/2` addresses: the one
  # thread in `Test.HostLive`, and the comments one (not the recorder) in
  # `Host`.
  @thread "#first-thread > [data-phx-component]"
  @isolated_thread "#isolated-host > [data-phx-component]:not(#recorder)"

  # An event sent straight at the component, as anyone who can see the page
  # can: the markup is not the control.
  defp push(view, selector, event, payload) do
    view |> with_target(selector) |> render_click(event, payload)
  end

  defp status_of(comment), do: Repo.get!(Comment, comment.uuid).status

  describe "client-supplied metadata" do
    test "a nested value is dropped, and the thread still renders for the next reader",
         %{conn: conn, scope: scope, r: r} do
      {:ok, view, _html} = mount_host(conn, scope, r)

      post_comment(view, %{
        "comment" => "with extras",
        "metadata" => %{"annotation_uuid" => %{"x" => "y"}, "note" => "kept"}
      })

      [comment] = PhoenixKitComments.list_comments("test_resource", r)
      refute Map.has_key?(comment.metadata, "annotation_uuid")
      assert comment.metadata["note"] == "kept"

      assert {:ok, _view, html} = mount_host(conn, scope, r)
      assert html =~ "with extras"
    end

    # A row stored before `client_metadata/2` kept to strings. The attribute
    # cannot print a map, and every render of the thread raised.
    test "a row already holding a map in its metadata renders",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment!(user, r, %{
        content: "stored before the fix",
        metadata: %{"annotation_uuid" => %{"x" => "y"}}
      })

      assert {:ok, _view, html} = mount_host(conn, scope, r)
      assert html =~ "stored before the fix"
      refute html =~ "data-annotation-uuid="
    end
  end

  describe "edits and deletes on a thread that is out of date" do
    test "an edit form left open is refused once the comment was deleted elsewhere",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_edit(view, comment)

      {:ok, _} = PhoenixKitComments.delete_comment(comment)

      html =
        view
        |> element("form[phx-submit='save_edit']")
        |> render_submit(%{"content" => "written after the delete"})

      assert html =~ "This comment is no longer available."
      assert %{status: "deleted", content: "original"} = Repo.get!(Comment, comment.uuid)
      refute_activity_logged("comments.comment_updated", resource_uuid: comment.uuid)
    end

    test "an edit form left open is refused once the comment was hidden elsewhere",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_edit(view, comment)

      {:ok, _} = PhoenixKitComments.hide_comment(comment)

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => "written after the hide"})

      assert %{status: "hidden", content: "original"} = Repo.get!(Comment, comment.uuid)
    end

    test "a comment deleted in another tab is not deleted again from this one",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)

      {:ok, _} = PhoenixKitComments.delete_comment(comment, actor_uuid: user.uuid)

      html =
        view
        |> element("button[phx-click='delete_comment'][phx-value-id='#{comment.uuid}']")
        |> render_click()

      assert html =~ "This comment had already been deleted."
      refute html =~ "Comment deleted"
      # One row: the real delete. The second click wrote another and fired
      # the host's `on_comment_deleted` a second time.
      assert_activity_logged("comments.comment_deleted", resource_uuid: comment.uuid)
    end

    test "opening an edit of a comment hidden elsewhere is refused",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)
      {:ok, _} = PhoenixKitComments.hide_comment(comment)

      html = open_edit(view, comment)

      assert html =~ "This comment is no longer available."
      refute has_element?(view, "form[phx-submit='save_edit']")
    end
  end

  describe "decorations" do
    setup %{user: user, r: r} do
      comment = comment!(user, r, %{content: "decorated", metadata: %{"annotation_uuid" => "a1"}})

      other =
        comment!(user, r, %{content: "also decorated", metadata: %{"annotation_uuid" => "a2"}})

      decorations = %{
        "annotation_uuid" => %{
          "a1" => %{label: "Sky shot", on_save: :renamed},
          "a2" => %{label: "Sea shot", on_save: :renamed}
        }
      }

      %{
        comment: comment,
        other: other,
        session: %{"resource_uuid" => r, "decorations" => decorations}
      }
    end

    # The edit form carries the label and the body together. The label used
    # to go to the host before the body's checks ran, so a refused edit still
    # renamed the host's record.
    test "the label reaches the host only when the body edit went through",
         %{conn: conn, comment: comment, session: session} = ctx do
      {:ok, view, _html} = isolated(conn, ctx, session)
      open_edit(view, comment)

      html =
        view
        |> element("form[phx-submit='save_edit']")
        |> render_submit(%{"content" => "   ", "label" => "New title"})

      assert html =~ "Comment can&#39;t be empty"
      refute_received {:decoration_update, _}

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => "edited", "label" => "New title"})

      assert_received {:decoration_update, %{action: :renamed, label: "New title"} = update}
      assert update.metadata_value == "a1"
      assert Repo.get!(Comment, comment.uuid).content == "edited"
    end

    test "opening an edit closes a title edit left open on another comment",
         %{conn: conn, comment: comment, other: other, session: session} = ctx do
      {:ok, view, _html} = isolated(conn, ctx, session)

      push(view, @isolated_thread, "begin_decoration_edit", %{
        "uuid" => other.uuid
      })

      assert has_element?(view, "[id$='-#{other.uuid}'][phx-submit='save_decoration']")

      open_edit(view, comment)

      refute has_element?(view, "[phx-submit='save_decoration']")

      assert has_element?(
               view,
               "form[phx-submit='save_edit'] input[name='label'][value='Sky shot']"
             )
    end
  end

  describe "replies" do
    test "a reply to a comment hidden since the box opened is refused",
         %{conn: conn, scope: scope, user: user, r: r} do
      parent = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)

      view
      |> element("button[phx-click='reply_to'][phx-value-id='#{parent.uuid}']")
      |> render_click()

      {:ok, _} = PhoenixKitComments.hide_comment(parent)

      html =
        view
        |> element("form[phx-submit='add_comment']")
        |> render_submit(%{"comment" => "a reply nobody would see"})

      assert html =~ "The comment you were replying to is no longer available."
      refute html =~ "Comment added"
      assert Repo.aggregate(from(c in Comment, where: c.parent_uuid == ^parent.uuid), :count) == 0
    end

    # The database answers lower case; a host may pass the uuid as it got it.
    test "a host passing the record's uuid in upper case can still reply, edit and delete",
         %{conn: conn, scope: scope, user: user, r: r} do
      parent = comment!(user, r, %{content: "the parent"})
      {:ok, view, _html} = mount_host(conn, scope, String.upcase(r))

      view
      |> element("button[phx-click='reply_to'][phx-value-id='#{parent.uuid}']")
      |> render_click()

      view
      |> element("form[phx-submit='add_comment']")
      |> render_submit(%{"comment" => "a reply"})

      assert Repo.aggregate(from(c in Comment, where: c.parent_uuid == ^parent.uuid), :count) ==
               1

      open_edit(view, parent)

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => "edited"})

      assert Repo.get!(Comment, parent.uuid).content == "edited"

      view
      |> element("button[phx-click='delete_comment'][phx-value-id='#{parent.uuid}']")
      |> render_click()

      assert status_of(parent) == "deleted"
    end

    test "an anonymous viewer cannot open a reply box",
         %{conn: conn, user: user, r: r} do
      parent = comment!(user, r)
      {:ok, view, _html} = live(conn, host_path(r))

      push(view, @thread, "reply_to", %{"id" => parent.uuid})

      refute has_element?(view, "form[phx-submit='add_comment']")
    end

    test "a [removed] placeholder cannot be replied to",
         %{conn: conn, scope: scope, user: user, r: r} do
      parent = comment!(user, r)
      comment!(user, r, %{content: "a reply keeps it in the tree", parent_uuid: parent.uuid})
      {:ok, _} = PhoenixKitComments.delete_comment(parent)
      {:ok, view, _html} = mount_host(conn, scope, r)

      push(view, @thread, "reply_to", %{"id" => parent.uuid})

      refute has_element?(view, "form[phx-submit='add_comment']")
    end

    # A host that keeps the component id and points it at another record.
    # The reply box for the old record's comment survived, was looked up in
    # the new tree, was not there — and neither composer rendered.
    test "pointing the thread at another record drops the open reply box",
         %{conn: conn, user: user, r: r} = ctx do
      parent = comment!(user, r)
      {:ok, view, _html} = isolated(conn, ctx, %{"resource_uuid" => r})

      view
      |> element("button[phx-click='reply_to'][phx-value-id='#{parent.uuid}']")
      |> render_click()

      assert has_element?(view, "form[phx-submit='add_comment']")

      render_click(view, "switch_resource", %{"uuid" => Ecto.UUID.generate()})

      refute has_element?(view, "form[phx-submit='add_comment']")
      assert has_element?(view, "button[phx-click='open_composer']")
    end
  end

  # What hosts pass for a preview of a record's comments.
  describe "a read-only thread (composer_position: nil)" do
    test "offers no Reply, and refuses a reply box and a post sent anyway",
         %{conn: conn, user: user, r: r} = ctx do
      comment = comment!(user, r, %{content: "read me"})

      {:ok, view, html} =
        isolated(conn, ctx, %{"resource_uuid" => r, "composer_position" => nil})

      assert html =~ "read me"
      refute has_element?(view, "button[phx-click='reply_to']")
      refute has_element?(view, "button[phx-click='open_composer']")

      push(view, @isolated_thread, "reply_to", %{"id" => comment.uuid})
      refute has_element?(view, "form[phx-submit='add_comment']")

      push(view, @isolated_thread, "add_comment", %{"comment" => "sneaked in"})
      assert [%{content: "read me"}] = PhoenixKitComments.list_comments("test_resource", r)
    end

    test "still lets the author edit their own comment",
         %{conn: conn, user: user, r: r} = ctx do
      comment = comment!(user, r)

      {:ok, view, _html} =
        isolated(conn, ctx, %{"resource_uuid" => r, "composer_position" => nil})

      open_edit(view, comment)
      assert has_element?(view, "form[phx-submit='save_edit']")
    end
  end

  describe "staged files" do
    setup do
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_attachments_enabled",
        true,
        "comments"
      )

      on_exit(fn ->
        PhoenixKit.Settings.update_boolean_setting_with_module(
          "comments_attachments_enabled",
          false,
          "comments"
        )
      end)

      :ok
    end

    # LiveView keeps a refused entry (wrong type, too large) staged — never
    # `done?` — until it is removed, so Post waited for it for ever.
    test "a refused file makes Post say so instead of waiting for ever",
         %{conn: conn, scope: scope, r: r} do
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_composer(view)

      input =
        file_input(view, "form[phx-submit='add_comment']", :attachment, [
          %{name: "setup.exe", content: "MZ", type: "application/x-msdownload"}
        ])

      render_upload(input, "setup.exe")

      html =
        view
        |> element("form[phx-submit='add_comment']")
        |> render_submit(%{"comment" => "with a refused file"})

      assert html =~ "Remove the files that can&#39;t be attached, then post again."
      refute html =~ "Wait for uploads to finish."
      assert PhoenixKitComments.list_comments("test_resource", r) == []
    end

    # Double-clicking a staged file's ✕ sends its ref twice; `cancel_upload/3`
    # raises on a ref that is no longer staged.
    test "cancelling a file that is no longer staged is a no-op",
         %{conn: conn, scope: scope, r: r} do
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_composer(view)

      push(view, @thread, "cancel_upload", %{"ref" => "0"})

      assert render(view) =~ "form"
    end
  end

  describe "malformed and unknown events" do
    for {event, payload} <- [
          {"reply_to", %{}},
          {"edit_comment", %{}},
          {"toggle_comment_expanded", %{}},
          {"select_giphy", %{}},
          {"cancel_upload", %{}},
          {"cancel_upload", %{"ref" => %{"x" => "y"}}},
          {"toggle_like", %{}},
          {"toggle_dislike", %{}},
          {"delete_comment", %{}},
          {"begin_decoration_edit", %{}},
          {"no_such_event", %{"x" => "y"}}
        ] do
      test "#{event} with #{inspect(payload)} leaves the host page standing",
           %{conn: conn, scope: scope, user: user, r: r} do
        comment!(user, r, %{content: "still here"})
        {:ok, view, _html} = mount_host(conn, scope, r)

        push(view, @thread, unquote(event), unquote(Macro.escape(payload)))

        assert render(view) =~ "still here"
      end
    end
  end

  describe "with moderation on" do
    setup do
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", true)
      on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("comments_moderation", false) end)
      :ok
    end

    # The new comment is pending and not in the thread; "Comment added" over
    # a thread without it read as a lost comment, and people posted again.
    test "a new comment says it is waiting for approval",
         %{conn: conn, scope: scope, r: r} do
      {:ok, view, _html} = mount_host(conn, scope, r)

      html = post_comment(view, %{"comment" => "needs a moderator"})

      assert html =~ "Your comment is awaiting approval."
      refute html =~ "Comment added"
      assert [%{status: "pending"}] = PhoenixKitComments.list_comments("test_resource", r)
    end
  end

  describe "the rich-text setting" do
    setup do
      on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("comments_rich_text", true) end)
      :ok
    end

    # The fix for a host whose Leaf hook hangs is to turn rich text off in
    # settings. Sampled once per component, it never reached a thread that
    # was already open.
    test "turning it off reaches a thread that is already open",
         %{conn: conn, scope: scope, r: r} do
      PhoenixKit.Settings.update_boolean_setting("comments_rich_text", true)
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_composer(view)
      refute has_element?(view, "textarea.textarea-sm[name='comment']")

      PhoenixKit.Settings.update_boolean_setting("comments_rich_text", false)
      # The partial update a host sends (`loaded?: false` to refresh, say):
      # it carries no `rich_text`, so the setting decides.
      Phoenix.LiveView.send_update(view.pid, PhoenixKitComments.Web.CommentsComponent,
        id: "test-thread"
      )

      render(view)

      assert has_element?(view, "textarea.textarea-sm[name='comment']")
    end
  end

  describe "text Postgres cannot store" do
    test "a comment with a NUL character is refused in words, not a crash",
         %{conn: conn, scope: scope, r: r} do
      {:ok, view, _html} = mount_host(conn, scope, r)

      html = post_comment(view, %{"comment" => "a\u0000b"})

      assert html =~ "The text contains a character that can&#39;t be saved."
      assert PhoenixKitComments.list_comments("test_resource", r) == []
    end

    test "an edit with a NUL character is refused in words, the comment unchanged",
         %{conn: conn, scope: scope, user: user, r: r} do
      comment = comment!(user, r)
      {:ok, view, _html} = mount_host(conn, scope, r)
      open_edit(view, comment)

      html =
        view
        |> element("form[phx-submit='save_edit']")
        |> render_submit(%{"content" => "a\u0000b"})

      assert html =~ "The text contains a character that can&#39;t be saved."
      assert status_of(comment) == "published"
      assert Repo.get!(Comment, comment.uuid).content == "original"
    end
  end
end
