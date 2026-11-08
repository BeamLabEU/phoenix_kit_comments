defmodule PhoenixKitComments.Integration.EditBroadcastTest do
  @moduledoc """
  Edits broadcast like creates and deletes do. Found on a host that renders
  the resource's latest comments inline and reloads on `{:comments_updated,
  _}`: an edited comment kept its old text there until a page reload,
  because only create/delete/reactions ever broadcast.
  """
  use PhoenixKitComments.DataCase, async: false

  setup do
    user = user_fixture()
    comment = comment_fixture(user)
    PhoenixKitComments.subscribe(comment.resource_type, comment.resource_uuid)
    {:ok, user: user, comment: comment}
  end

  test "a body edit broadcasts :updated on the resource's topic", %{comment: comment} do
    assert {:ok, _} = PhoenixKitComments.update_comment(comment, %{content: "edited body"})

    assert_receive {:comments_updated,
                    %{resource_type: type, resource_uuid: uuid, action: :updated}}

    assert type == comment.resource_type
    assert uuid == comment.resource_uuid
  end

  test "a status change (hide / restore) broadcasts too — it changes what a subscriber shows",
       %{comment: comment} do
    assert {:ok, hidden} = PhoenixKitComments.hide_comment(comment)
    assert_receive {:comments_updated, %{action: :updated}}

    # Restore brings back a DELETED comment only (a hidden one is refused).
    assert {:ok, deleted} = PhoenixKitComments.delete_comment(hidden)
    assert_receive {:comments_updated, %{action: :deleted}}

    assert {:ok, _} = PhoenixKitComments.restore_comment(deleted)
    assert_receive {:comments_updated, %{action: :updated}}
  end

  test "a transition to the state the comment is already in announces nothing",
       %{comment: comment} do
    assert {:ok, hidden} = PhoenixKitComments.hide_comment(comment)
    assert_receive {:comments_updated, %{action: :updated}}

    assert {:ok, _} = PhoenixKitComments.hide_comment(hidden)
    refute_receive {:comments_updated, _}, 100
  end

  test "a delete broadcasts :deleted exactly once, not :updated as well", %{comment: comment} do
    assert {:ok, _} = PhoenixKitComments.delete_comment(comment)

    assert_receive {:comments_updated, %{action: :deleted}}
    refute_receive {:comments_updated, %{action: :updated}}, 100
  end

  test "broadcast: false keeps a wrapping caller in charge of its own message", %{
    comment: comment
  } do
    assert {:ok, _} =
             PhoenixKitComments.update_comment(comment, %{content: "quiet"}, broadcast: false)

    refute_receive {:comments_updated, _}, 100
  end

  test "a failed update broadcasts nothing", %{comment: comment} do
    assert {:error, _} = PhoenixKitComments.update_comment(comment, %{content: ""})
    refute_receive {:comments_updated, _}, 100
  end
end
