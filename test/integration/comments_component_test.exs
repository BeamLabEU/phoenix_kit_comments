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

  # `PhoenixKitCommentsPasteFiles` (priv/static/assets/phoenix_kit_comments.js)
  # takes a paste with files and no text, and either hands the files to the
  # composer's `:attachment` upload or pushes `paste_refused`. LiveViewTest
  # runs no browser JS, so these drive the two server ends of that hook —
  # the wrapper it reads, the upload it feeds, the refusal it pushes — across
  # every shape a paste arrives in and every rule it meets.
  describe "a pasted file" do
    setup do
      on_exit(fn ->
        set_attachments(false)
        PhoenixKit.Settings.update_setting("comments_max_attachments", "4")
        PhoenixKit.Settings.update_setting("comments_attachment_max_size_mb", "20")
      end)

      :ok
    end

    defp set_attachments(on?) do
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_attachments_enabled",
        on?,
        "comments"
      )
    end

    defp open_composer(conn, scope, resource_uuid) do
      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))
      view |> element("button[phx-click='open_composer']") |> render_click()
      view
    end

    defp open_edit(conn, scope, user, resource_uuid) do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", resource_uuid, user.uuid, %{
          content: "original"
        })

      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))

      view
      |> element("button[phx-click='edit_comment'][phx-value-id='#{comment.uuid}']")
      |> render_click()

      {view, comment}
    end

    defp paste_refused(view, wrapper, payload) do
      view |> element(wrapper) |> render_hook("paste_refused", payload)
    end

    defp pasted(name, type, bytes) do
      %{name: name, content: :binary.copy("x", bytes), type: type}
    end

    defp upload_pasted(view, files) do
      input = file_input(view, "form[phx-submit='add_comment']", :attachment, files)
      render_upload(input, hd(files).name)
      render(view)
    end

    @composer_wrapper ~s(form[phx-submit='add_comment'] [phx-hook="PhoenixKitCommentsPasteFiles"])
    @edit_wrapper ~s(form[phx-submit='save_edit'] [phx-hook="PhoenixKitCommentsPasteFiles"])

    test "the hook wraps the editor only once the composer is open",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))
      refute has_element?(view, ~s([phx-hook="PhoenixKitCommentsPasteFiles"]))

      view |> element("button[phx-click='open_composer']") |> render_click()
      assert has_element?(view, @composer_wrapper)
    end

    # The hook's whole decision is `data-attachments`: "true" uploads into
    # the form's file input, anything else refuses. Both must agree with the
    # setting, and the input must exist exactly when it says "true".
    for {on?, attr} <- [{true, "true"}, {false, "false"}] do
      test "with attachments #{if on?, do: "on", else: "off"} the composer says #{attr} and the input agrees",
           %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
        set_attachments(unquote(on?))
        view = open_composer(conn, scope, resource_uuid)

        assert has_element?(
                 view,
                 ~s(form[phx-submit='add_comment'] [phx-hook="PhoenixKitCommentsPasteFiles"][data-attachments="#{unquote(attr)}"][data-refuse="attachments_off"][data-upload-name="attachment"])
               )

        assert has_element?(
                 view,
                 ~s(form[phx-submit='add_comment'] input[type="file"][name="attachment"])
               ) ==
                 unquote(on?)
      end

      test "with attachments #{if on?, do: "on", else: "off"} an edit refuses pasted files",
           %{conn: conn, scope: scope, user: user, resource_uuid: resource_uuid} do
        set_attachments(unquote(on?))
        {view, _comment} = open_edit(conn, scope, user, resource_uuid)

        assert has_element?(
                 view,
                 ~s(form[phx-submit='save_edit'] [phx-hook="PhoenixKitCommentsPasteFiles"][data-attachments="false"][data-refuse="editing"])
               )

        refute has_element?(view, ~s(form[phx-submit='save_edit'] input[type="file"]))
      end
    end

    # A component's flash never reaches the page (LiveView copies it to the
    # parent only on push_navigate/push_patch), so a refusal is shown in the
    # form itself — asserted on the rendered page, where a person sees it.
    for {reason, message} <- [
          {"attachments_off", "Files can't be attached to comments here."},
          {"attach_failed", "The pasted file could not be attached. Try the attach button."}
        ] do
      test "the #{reason} refusal is shown in the composer",
           %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
        view = open_composer(conn, scope, resource_uuid)
        paste_refused(view, @composer_wrapper, %{"reason" => unquote(reason)})

        assert view |> element("[data-composer-notice=composer]") |> render() =~
                 html_escape(unquote(message))

        assert comments_for(resource_uuid) == []
      end
    end

    test "an editing refusal is shown in the edit form, not the composer",
         %{conn: conn, scope: scope, user: user, resource_uuid: resource_uuid} do
      {view, comment} = open_edit(conn, scope, user, resource_uuid)
      paste_refused(view, @edit_wrapper, %{"reason" => "editing"})

      assert view
             |> element("form[phx-submit='save_edit'] [data-composer-notice=edit]")
             |> render() =~
               html_escape(
                 "Files can't be added while editing a comment. Add them to a new comment."
               )

      assert Repo.get!(Comment, comment.uuid).content == "original"

      view |> element("button[phx-click='cancel_edit']") |> render_click()
      refute has_element?(view, "[data-composer-notice]")
    end

    test "a refusal with no reason is the generic one, not a crash",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      view = open_composer(conn, scope, resource_uuid)
      paste_refused(view, @composer_wrapper, %{})

      assert render(view) =~ html_escape("Files can't be attached to comments here.")
    end

    test "typing clears the refusal",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      view = open_composer(conn, scope, resource_uuid)
      paste_refused(view, @composer_wrapper, %{"reason" => "attachments_off"})
      assert has_element?(view, "[data-composer-notice=composer]")

      view
      |> element("form[phx-submit='add_comment']")
      |> render_change(%{"comment" => "never mind"})

      refute has_element?(view, "[data-composer-notice]")
    end

    # What the hook hands over, through the input it targets. Every shape a
    # paste can carry meets the same rules as the attach button.
    test "one pasted image is staged as an attachment",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      set_attachments(true)
      view = open_composer(conn, scope, resource_uuid)

      html = upload_pasted(view, [pasted("pasted-2026-10-29T10-00-00.png", "image/png", 100)])

      assert html =~ "pasted-2026-10-29T10-00-00.png"
      refute html =~ "File type not allowed"
      assert comments_for(resource_uuid) == []
    end

    test "several pasted files are staged together",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      set_attachments(true)
      view = open_composer(conn, scope, resource_uuid)

      html =
        upload_pasted(view, [
          pasted("pasted-a.png", "image/png", 100),
          pasted("pasted-a-2.jpg", "image/jpeg", 100),
          pasted("notes.pdf", "application/pdf", 100)
        ])

      for name <- ["pasted-a.png", "pasted-a-2.jpg", "notes.pdf"], do: assert(html =~ name)
      refute html =~ "Too many files"
    end

    test "a pasted file of a type comments do not take is refused by the upload",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      set_attachments(true)
      view = open_composer(conn, scope, resource_uuid)

      input =
        file_input(view, "form[phx-submit='add_comment']", :attachment, [
          pasted("setup.exe", "application/x-msdownload", 100)
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "setup.exe")
    end

    test "more pasted files than the cap are refused",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      set_attachments(true)
      PhoenixKit.Settings.update_setting("comments_max_attachments", "2")
      view = open_composer(conn, scope, resource_uuid)

      input =
        file_input(view, "form[phx-submit='add_comment']", :attachment, [
          pasted("a.png", "image/png", 100),
          pasted("b.png", "image/png", 100),
          pasted("c.png", "image/png", 100)
        ])

      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "a.png")
    end

    test "a pasted file over the size cap is refused",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      set_attachments(true)
      PhoenixKit.Settings.update_setting("comments_attachment_max_size_mb", "1")
      view = open_composer(conn, scope, resource_uuid)

      input =
        file_input(view, "form[phx-submit='add_comment']", :attachment, [
          pasted("big.png", "image/png", 1_048_577)
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.png")
    end

    # The text-side guard: an image the editor wrote INTO the text (a
    # browser still running the script from before the hook) — on a new
    # comment and on an edit alike.
    @inline "the wall ![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAE=)"

    test "an image written into a new comment's text is refused in words",
         %{conn: conn, scope: scope, resource_uuid: resource_uuid} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), host_path(resource_uuid))
      post_comment(view, %{"comment" => @inline})

      assert comments_for(resource_uuid) == []

      assert render(view) =~
               html_escape(
                 "Images can't be pasted into the text. Paste the image again to attach it."
               )

      # The composer stays open; without the image it posts.
      view
      |> element("form[phx-submit='add_comment']")
      |> render_submit(%{"comment" => "the wall is 3420"})

      assert [_] = comments_for(resource_uuid)
    end

    test "an image written into an edit's text is refused, the comment unchanged",
         %{conn: conn, scope: scope, user: user, resource_uuid: resource_uuid} do
      {view, comment} = open_edit(conn, scope, user, resource_uuid)

      view
      |> element("form[phx-submit='save_edit']")
      |> render_submit(%{"content" => @inline})

      assert Repo.get!(Comment, comment.uuid).content == "original"

      assert view |> element("[data-composer-notice=edit]") |> render() =~
               html_escape(
                 "Files can't be added while editing a comment. Add them to a new comment."
               )
    end
  end

  defp html_escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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
