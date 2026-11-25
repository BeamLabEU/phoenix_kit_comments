defmodule PhoenixKitComments.MentionModerationTest do
  @moduledoc """
  Mentions in a comment held for moderation ping nobody until a moderator
  approves it (its text would otherwise reach the mentioned people before
  anyone saw it), and a notification's link lands on the comment even when
  the record's own path carries a fragment (review of 2026-11-24).
  """
  use PhoenixKitComments.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Mentions.Mention
  alias PhoenixKitComments.Test.Repo
  alias PhoenixKitComments.Web.CommentsComponent

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    PhoenixKit.Settings.update_boolean_setting("comments_moderation", true)
    on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("comments_moderation", false) end)

    author = user_fixture()
    ada = user_fixture(%{first_name: "Ada", last_name: "Lovelace"})
    %{author: author, ada: ada, resource_uuid: Ecto.UUID.generate()}
  end

  defp mentions_of(user) do
    Repo.all(
      from(m in Mention, where: m.target_uuid == ^user.uuid and m.source_type == "comment")
    )
  end

  defp pending_mentioning(author, ada, r) do
    {:ok, comment} =
      PhoenixKitComments.create_comment("test_resource", r, author.uuid, %{
        "content" => "Hi @[user:#{ada.uuid}|Ada Lovelace], the client offered 40k"
      })

    assert comment.status == "pending"
    # What the composer does after every successful insert.
    PhoenixKitComments.sync_comment_mentions(comment, author.uuid)
    comment
  end

  test "a pending comment pings nobody; its approval does", %{
    author: author,
    ada: ada,
    resource_uuid: r
  } do
    comment = pending_mentioning(author, ada, r)
    assert mentions_of(ada) == []

    {:ok, approved} = PhoenixKitComments.approve_comment(comment)
    assert approved.status == "published"
    assert [%Mention{actor_uuid: actor}] = mentions_of(ada)
    assert actor == author.uuid
  end

  test "a pending comment deleted unapproved never pings", %{
    author: author,
    ada: ada,
    resource_uuid: r
  } do
    comment = pending_mentioning(author, ada, r)
    {:ok, _} = PhoenixKitComments.delete_comment(comment)
    assert mentions_of(ada) == []
  end

  defp pings(user) do
    Repo.all(
      from(e in PhoenixKit.Activity.Entry,
        where: e.action == "mention.created" and e.target_uuid == ^user.uuid,
        select: e.uuid
      )
    )
    |> length()
  end

  test "held, then hidden, then approved: its mentions ping once, at that first publication",
       %{author: author, ada: ada, resource_uuid: r} do
    comment = pending_mentioning(author, ada, r)
    {:ok, hidden} = PhoenixKitComments.hide_comment(comment)
    assert hidden.status == "hidden"
    assert pings(ada) == 0

    {:ok, approved} = PhoenixKitComments.approve_comment(hidden)
    assert approved.status == "published"
    assert pings(ada) == 1
  end

  test "published, hidden, approved again: nobody is told a second time",
       %{author: author, ada: ada, resource_uuid: r} do
    comment = pending_mentioning(author, ada, r)
    {:ok, approved} = PhoenixKitComments.approve_comment(comment)
    assert pings(ada) == 1

    {:ok, hidden} = PhoenixKitComments.hide_comment(approved)
    {:ok, _} = PhoenixKitComments.approve_comment(hidden)
    assert pings(ada) == 1
  end

  test "approving a comment twice pings once", %{author: author, ada: ada, resource_uuid: r} do
    comment = pending_mentioning(author, ada, r)
    {:ok, _} = PhoenixKitComments.approve_comment(comment)
    {:ok, _} = PhoenixKitComments.approve_comment(comment)
    assert [_] = mentions_of(ada)
  end

  test "delayed sync skips an older body and a hidden comment",
       %{author: author, ada: ada, resource_uuid: r} do
    PhoenixKit.Settings.update_boolean_setting("comments_moderation", false)

    {:ok, original} =
      PhoenixKitComments.create_comment("test_resource", r, author.uuid, %{
        content: "Original @[user:#{ada.uuid}|Ada]"
      })

    {:ok, edited} =
      PhoenixKitComments.update_comment(
        original,
        %{content: "Edited @[user:#{ada.uuid}|Ada]"}
      )

    PhoenixKitComments.sync_comment_mentions(original, author.uuid)
    assert mentions_of(ada) == []
    {:ok, _hidden} = PhoenixKitComments.hide_comment(edited)
    PhoenixKitComments.sync_comment_mentions(edited, author.uuid)
    assert mentions_of(ada) == []
    assert pings(ada) == 0
  end

  test "restoring directly to published delivers a previously held mention",
       %{author: author, ada: ada, resource_uuid: r} do
    comment = pending_mentioning(author, ada, r)
    {:ok, deleted} = PhoenixKitComments.delete_comment(comment)
    PhoenixKit.Settings.update_boolean_setting("comments_moderation", false)
    {:ok, %{status: "published"}} = PhoenixKitComments.restore_comment(deleted)
    assert pings(ada) == 1
  end

  describe "the link of a record whose path has a fragment" do
    setup do
      previous = PhoenixKit.ResourceLinks.get_resource_path_templates()

      PhoenixKit.ResourceLinks.update_resource_path_templates(%{
        "test_resource" => "/things/:uuid?tab=talk#row-:uuid"
      })

      on_exit(fn -> PhoenixKit.ResourceLinks.update_resource_path_templates(previous) end)
      :ok
    end

    test "carries the comment's anchor as its only fragment", %{author: author, resource_uuid: r} do
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", false)

      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", r, author.uuid, %{"content" => "Hi"})

      link = CommentsComponent.comment_link(comment)
      assert link =~ "/things/#{r}"
      assert String.ends_with?(link, "#pk-comment-#{comment.uuid}")
      assert link |> String.graphemes() |> Enum.count(&(&1 == "#")) == 1
    end
  end
end
