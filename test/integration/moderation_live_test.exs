defmodule PhoenixKitComments.Web.ModerationLiveTest do
  @moduledoc """
  The moderation admin page, driven through the real LiveView.

  This file exists because of what shipped without it. Approve and Restore
  were wired to each other's context functions: with moderation on, Approve
  called `restore_comment/2` and left the comment `pending` while flashing
  "Comment approved", and Restore called `approve_comment/2` and published a
  deleted comment that had never been approved. Every context-layer test
  passed throughout — `approve_comment/2` and `restore_comment/2` were both
  correct in isolation. Only clicking the button catches it.

  So each test asserts the RESULTING STATUS and the audit row's `action`
  **and** `actor_uuid`. Asserting merely that some row exists would pass
  against the swapped wiring, and asserting the status alone would pass
  against a handler that drops the actor.
  """
  use PhoenixKitComments.LiveCase

  alias PhoenixKitComments.Comment

  @path "/en/admin/comments"

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")

    # Moderation ON is the configuration the swap broke, and the one where
    # approve/restore differ at all. With it off both set "published" and the
    # bug is invisible.
    PhoenixKit.Settings.update_boolean_setting_with_module(
      "comments_moderation",
      true,
      "comments"
    )

    on_exit(fn ->
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "comments_moderation",
        false,
        "comments"
      )
    end)

    moderator = user_fixture()
    author = user_fixture()

    %{moderator: moderator, author: author, scope: fake_scope(user: moderator)}
  end

  defp comment_with_status(author, status) do
    {:ok, comment} =
      PhoenixKitComments.create_comment(
        "test_resource",
        Ecto.UUID.generate(),
        author.uuid,
        %{content: "a comment #{System.unique_integer([:positive])}"}
      )

    {1, _} =
      Repo.update_all(from(c in Comment, where: c.uuid == ^comment.uuid), set: [status: status])

    Repo.get!(Comment, comment.uuid)
  end

  defp status_of(comment), do: Repo.get!(Comment, comment.uuid).status

  describe "approve" do
    test "publishes a pending comment and logs the approval against the moderator",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "pending")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "approve", %{"uuid" => comment.uuid})

      # The bug: this said "published" while the row stayed "pending".
      assert status_of(comment) == "published"
      assert html =~ "Comment approved"

      assert_activity_logged("comments.comment_approved",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )
    end

    test "refuses a deleted comment instead of publishing it",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "deleted")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      # The row menu hides Approve on a deleted row, and the bulk path was
      # taught to refuse one — but the single-row handler took whatever uuid
      # the event carried and flashed success without looking at the result,
      # so a replayed `approve` published a deleted comment and told the
      # admin it had worked.
      html = render_click(view, "approve", %{"uuid" => comment.uuid})

      assert status_of(comment) == "deleted"
      assert html =~ "Could not approve this comment"
      refute html =~ "Comment approved"
      refute_activity_logged("comments.comment_approved", resource_uuid: comment.uuid)
    end

    test "writes exactly one audit row, not one per inner update",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "pending")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      render_click(view, "approve", %{"uuid" => comment.uuid})

      # `approve_comment/2` pipes through `update_comment/3`, which logs on
      # its own unless told not to — so this used to record both
      # `comment_updated` and `comment_approved` for one click.
      refute_activity_logged("comments.comment_updated", resource_uuid: comment.uuid)
    end
  end

  describe "restore" do
    test "returns a deleted comment to the queue rather than publishing it",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "deleted")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "restore", %{"uuid" => comment.uuid})

      # The point of `restore_comment/2`: undoing a delete must not also
      # approve something that was never approved. The swapped wiring
      # published it.
      assert status_of(comment) == "pending"
      refute status_of(comment) == "published"
      assert html =~ "Comment restored"

      assert_activity_logged("comments.comment_restored",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )
    end
  end

  describe "hide and delete" do
    test "hide sets hidden and logs against the moderator",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "published")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "hide", %{"uuid" => comment.uuid})

      assert status_of(comment) == "hidden"
      assert html =~ "Comment hidden"

      assert_activity_logged("comments.comment_hidden",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )

      refute_activity_logged("comments.comment_updated", resource_uuid: comment.uuid)
    end

    test "delete soft-deletes and logs against the moderator",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "published")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "delete", %{"uuid" => comment.uuid})

      assert status_of(comment) == "deleted"
      assert html =~ "Comment deleted"

      assert_activity_logged("comments.comment_deleted",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )
    end
  end

  describe "authorization" do
    test "a scope without the comments permission cannot moderate",
         %{conn: conn, author: author} do
      comment = comment_with_status(author, "pending")

      # No admin-area access at all: mount itself must refuse.
      scope = fake_scope(roles: [], permissions: [], authenticated?: true)

      # `push_navigate` from mount, so this is a live_redirect — and the
      # flash is part of the contract: refusing silently would look like the
      # page simply being empty.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(put_test_scope(conn, scope), @path)

      assert to =~ "/admin"
      assert flash["error"] =~ "do not have access"
      assert status_of(comment) == "pending"
    end

    test "a missing comment reports not-found rather than crashing",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "approve", %{"uuid" => Ecto.UUID.generate()})

      assert html =~ "Comment not found"
    end
  end

  describe "bulk actions" do
    test "bulk approve publishes pending comments and logs the approval",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "pending")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "bulk_approve", %{"uuids" => [comment.uuid]})

      assert status_of(comment) == "published"
      # One whole sentence per action and count (it used to splice a
      # translated "approved" into "%{count} comment %{action}").
      assert html =~ "1 comment approved"

      # The single-row path was fixed to log the moderation action; the bulk
      # path wrote the status directly and left `comment_updated` behind.
      assert_activity_logged("comments.comment_approved",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )
    end

    test "bulk approve refuses a deleted comment instead of publishing it",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "deleted")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "bulk_approve", %{"uuids" => [comment.uuid]})

      # The failure said so in English but read as the success message in
      # Estonian and Russian, whose translations dropped "could not be".
      assert html =~ "1 comment could not be approved"

      # The row menu hides Approve on a deleted comment for a reason:
      # approving must never mean undeleting. Selecting the same row and
      # using the always-visible bulk button published it anyway — the
      # single-row swap this file was written for, still live one control over.
      assert status_of(comment) == "deleted"
      refute_activity_logged("comments.comment_approved", resource_uuid: comment.uuid)
    end

    test "bulk hide logs the hide, not a bare update",
         %{conn: conn, scope: scope, moderator: moderator, author: author} do
      comment = comment_with_status(author, "published")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html = render_click(view, "bulk_hide", %{"uuids" => [comment.uuid]})

      assert status_of(comment) == "hidden"
      assert html =~ "1 comment hidden"

      assert_activity_logged("comments.comment_hidden",
        resource_uuid: comment.uuid,
        actor_uuid: moderator.uuid
      )
    end
  end

  describe "the bulk bar" do
    test "sits inside the selection scope, where core's hook looks for it",
         %{conn: conn, scope: scope, author: author} do
      comment_with_status(author, "pending")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      # The hook searches its own element only. Rendered above the scope, the
      # bar never showed and its buttons were never wired: bulk moderation
      # could not be reached from the page.
      for action <- ~w(bulk_approve bulk_hide bulk_delete_comments) do
        assert has_element?(view, ~s(#comments-bulk [data-bulk-action="#{action}"]))
      end

      assert has_element?(view, ~s(#comments-bulk [data-bulk-show="has-selection"]))
      assert has_element?(view, "#comments-bulk [data-bulk-text-template]")
    end

    test "a selected comment that is gone counts as a failure",
         %{conn: conn, scope: scope, author: author} do
      comment_with_status(author, "pending")
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      # Deleted in another tab, or outside the viewer's rule: the bulk
      # functions drop it rather than count it, which flashed
      # "0 comments approved" as a success.
      html = render_click(view, "bulk_approve", %{"uuids" => [Ecto.UUID.generate()]})

      assert html =~ "1 comment could not be approved"
    end

    test "a malformed selection answers that nothing is selected",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      assert render_hook(view, "bulk_approve", %{"uuids" => "everything"}) =~
               "No comments selected"

      assert render_hook(view, "bulk_hide", %{}) =~ "No comments selected"
    end
  end

  describe "crafted events and URLs" do
    test "a row action without a uuid answers like a missing comment",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      # No `"uuid"` key had no clause to match and took the page down.
      for event <- ~w(approve hide delete restore) do
        assert render_hook(view, event, %{}) =~ "Comment not found"
      end

      render_hook(view, "view_comment", %{})
      refute has_element?(view, ".modal-open")
    end

    test "URL params of the wrong shape fall back to the defaults",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "pending")
      conn = put_test_scope(conn, scope)

      for query <- ~w(?search[x]=1 ?page[]=1 ?resource_type[x]=1 ?status[]=x ?status=bogus) do
        assert {:ok, _view, html} = live(conn, @path <> query), "crashed on #{query}"
        assert html =~ comment.content, "#{query} did not fall back to the full list"
      end
    end
  end

  describe "pagination" do
    test "a page past the end shows the last page instead of nothing",
         %{conn: conn, scope: scope, author: author} do
      for _ <- 1..21, do: comment_with_status(author, "pending")

      {:ok, view, html} = live(put_test_scope(conn, scope), @path <> "?page=9")

      # Approving the last row of the last page under a filter, or a
      # hand-edited `?page=`, left "No comments found" and no way back.
      refute html =~ "No comments found"
      assert has_element?(view, ".join-item.btn-active", "2")
    end

    test "a page number too large for the query is clamped, not a crash",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "pending")

      {:ok, _view, html} =
        live(put_test_scope(conn, scope), @path <> "?page=99999999999999999999")

      assert html =~ comment.content
    end
  end

  describe "dates" do
    test "follow the site's date format instead of English month names",
         %{conn: conn, scope: scope, author: author} do
      comment = comment_with_status(author, "published")
      {:ok, _view, html} = live(put_test_scope(conn, scope), @path)

      # `Calendar.strftime(…, "%b %d, %Y")` printed "Nov 08, 2026" on every
      # locale. The site's `date_format` defaults to Y-m-d.
      assert html =~ comment.inserted_at |> NaiveDateTime.to_date() |> Date.to_iso8601()
      refute html =~ Calendar.strftime(comment.inserted_at, "%b %d, %Y")
    end
  end

  describe "status labels" do
    test "the badge renders the translated label, not the raw enum",
         %{conn: conn, scope: scope, author: author} do
      comment_with_status(author, "pending")
      {:ok, _view, html} = live(put_test_scope(conn, scope), @path)

      # Asserted on the BADGES, not on the page. The filter dropdown and the
      # stat tiles on this same page always used gettext and already render
      # "Pending", so `html =~ "Pending"` passed with the badge printing the
      # raw enum — the exact regression this test is named for. Both surfaces
      # (table cell and grid card) render one, and both must be translated.
      labels =
        ~r{<span class="badge badge-warning badge-sm">\s*([^<]*?)\s*</span>}
        |> Regex.scan(html)
        |> Enum.map(fn [_, label] -> label end)

      assert labels != []

      assert Enum.all?(labels, &(&1 == "Pending")),
             "raw enum in a status badge: #{inspect(labels)}"
    end
  end

  describe "filters and search" do
    test "searching narrows the list through the URL, and clearing widens it again",
         %{conn: conn, scope: scope, author: author} do
      wanted = comment_with_status(author, "published")
      other = comment_with_status(author, "published")

      {1, _} =
        Repo.update_all(from(c in Comment, where: c.uuid == ^wanted.uuid),
          set: [content: "needle in a haystack"]
        )

      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html =
        view
        |> form("#comment-filters-desktop", %{"search" => %{"query" => "needle"}})
        |> render_change()

      assert html =~ "needle in a haystack"
      refute html =~ other.content
      assert assert_patch(view) =~ "search=needle"

      html = render_click(view, "clear_search", %{})
      assert html =~ other.content
    end

    test "a status filter lists that status only", %{conn: conn, scope: scope, author: author} do
      pending = comment_with_status(author, "pending")
      published = comment_with_status(author, "published")

      {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

      html =
        view
        |> form("#comment-filters-desktop", %{"filter" => %{"status" => "pending"}})
        |> render_change()

      assert html =~ pending.content
      refute html =~ published.content

      html = render_click(view, "clear_filters", %{})
      assert html =~ published.content
    end
  end
end
