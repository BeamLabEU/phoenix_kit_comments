defmodule PhoenixKitComments.Integration.ContextHardeningTest do
  @moduledoc """
  The context's answers to inputs and states a caller should never have to
  guard against: a transition from the wrong state, a repeat of one already
  made, a missing row behind a valid uuid, a NUL byte, an out-of-range page,
  string-keyed params, a reply naming another record's comment. Each of
  these used to raise, or to succeed with side effects it should not have.
  """

  use PhoenixKitComments.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitComments.Comment

  # The handler below raises on every create, on purpose (see the last
  # test); its warnings would otherwise fill the run's output.
  @moduletag :capture_log

  defmodule Handler do
    @moduledoc false
    @behaviour PhoenixKitComments.ResourceHandler

    defp tell(msg), do: send(:persistent_term.get({__MODULE__, :pid}), msg)

    @impl true
    def on_comment_deleted(_type, _uuid, comment), do: tell({:deleted, comment.uuid})

    @impl true
    def on_comment_liked(_type, _uuid, %{comment: c}), do: tell({:liked, c.uuid})

    @impl true
    def on_comment_unliked(_type, _uuid, %{comment: c}), do: tell({:unliked, c.uuid})

    @impl true
    def on_comment_disliked(_type, _uuid, %{comment: c}), do: tell({:disliked, c.uuid})

    @impl true
    def on_comment_undisliked(_type, _uuid, %{comment: c}), do: tell({:undisliked, c.uuid})

    # A host handler with a bug: it matches on the comment and crashes.
    @impl true
    def on_comment_created(_type, _uuid, %{status: "never"}), do: :ok
  end

  @type_name "hardening_probe"

  setup do
    :persistent_term.put({Handler, :pid}, self())
    previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)
    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{@type_name => Handler})

    on_exit(fn ->
      :persistent_term.erase({Handler, :pid})

      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
    end)

    author = user_fixture()

    %{author: author, comment: comment_fixture(author, %{resource_type: @type_name})}
  end

  defp status_of(comment), do: Repo.get!(Comment, comment.uuid).status

  describe "moderation transitions" do
    test "hiding a deleted comment is refused, so Approve can't undelete it",
         %{comment: comment} do
      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)

      assert {:error, :comment_deleted} = PhoenixKitComments.hide_comment(deleted)
      assert {0, 1} = PhoenixKitComments.bulk_hide([comment.uuid])
      assert status_of(comment) == "deleted"
      refute_activity_logged("comments.comment_hidden", resource_uuid: comment.uuid)
    end

    test "restore brings back only a deleted comment", %{comment: comment} do
      assert {:error, :not_deleted} = PhoenixKitComments.restore_comment(comment)
      {:ok, hidden} = PhoenixKitComments.hide_comment(comment)
      assert {:error, :not_deleted} = PhoenixKitComments.restore_comment(hidden)
      assert status_of(comment) == "hidden"
      refute_activity_logged("comments.comment_restored", resource_uuid: comment.uuid)
    end

    test "restore queues the comment again under moderation", %{comment: comment} do
      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)
      {:ok, _} = Settings.update_boolean_setting("comments_moderation", true)

      assert {:ok, %Comment{status: "pending"}} = PhoenixKitComments.restore_comment(deleted)
    after
      Settings.update_boolean_setting("comments_moderation", false)
    end

    test "deleting twice has the side effects of one delete", %{comment: comment} do
      uuid = comment.uuid
      assert {:ok, _} = PhoenixKitComments.delete_comment(comment)
      assert_received {:deleted, ^uuid}

      # A stale struct (a second tab) and a bulk delete over the same row.
      assert {:error, :already_deleted} = PhoenixKitComments.delete_comment(comment)
      assert {0, 1} = PhoenixKitComments.bulk_update_status([uuid], "deleted")

      refute_received {:deleted, ^uuid}
      assert_activity_logged("comments.comment_deleted", resource_uuid: uuid)
    end

    test "approving a published comment again writes nothing", %{comment: comment} do
      assert {:ok, %Comment{status: "published"}} = PhoenixKitComments.approve_comment(comment)
      refute_activity_logged("comments.comment_approved", resource_uuid: comment.uuid)
    end

    test "a transition on a comment that no longer exists is :not_found" do
      ghost = %Comment{uuid: UUIDv7.generate()}

      assert {:error, :not_found} = PhoenixKitComments.approve_comment(ghost)
      assert {:error, :not_found} = PhoenixKitComments.hide_comment(ghost)
      assert {:error, :not_found} = PhoenixKitComments.delete_comment(ghost)
      assert {:error, :not_found} = PhoenixKitComments.restore_comment(ghost)
    end

    test "bulk_update_status means what the single-row function means", %{comment: comment} do
      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)

      # It used to write "published" straight onto a deleted row.
      assert {0, 1} = PhoenixKitComments.bulk_update_status([deleted.uuid], "published")
      assert {0, 1} = PhoenixKitComments.bulk_update_status([deleted.uuid], "pending")
      assert status_of(comment) == "deleted"
    end

    test "a bulk approve logs comment_approved", %{author: author} do
      pending = comment_fixture(author, %{resource_type: @type_name, status: "pending"})

      assert {1, 0} = PhoenixKitComments.bulk_update_status([pending.uuid], "published")
      assert_activity_logged("comments.comment_approved", resource_uuid: pending.uuid)
      refute_activity_logged("comments.comment_updated", resource_uuid: pending.uuid)
    end
  end

  describe "foreign keys come back as errors" do
    test "an author that does not exist", %{comment: comment} do
      ghost = UUIDv7.generate()

      assert {:error, %Ecto.Changeset{} = changeset} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), ghost, %{
                 content: "hi"
               })

      assert changeset.errors[:user_uuid]
      assert {:error, %Ecto.Changeset{}} = PhoenixKitComments.like_comment(comment.uuid, ghost)
    end

    test "a reaction to a comment that does not exist", %{author: author} do
      ghost = UUIDv7.generate()

      assert {:error, :not_found} = PhoenixKitComments.like_comment(ghost, author.uuid)
      assert {:error, :not_found} = PhoenixKitComments.dislike_comment(ghost, author.uuid)
      assert {:error, :not_found} = PhoenixKitComments.unlike_comment(ghost, author.uuid)
      assert {:error, :not_found} = PhoenixKitComments.like_comment("nope", author.uuid)
    end
  end

  describe "reactions" do
    test "switching a dislike to a like reports both changes", %{comment: comment, author: author} do
      uuid = comment.uuid
      {:ok, :disliked} = PhoenixKitComments.dislike_comment(uuid, author.uuid)
      assert_received {:disliked, ^uuid}

      {:ok, :liked} = PhoenixKitComments.like_comment(uuid, author.uuid)
      assert_received {:undisliked, ^uuid}
      assert_received {:liked, ^uuid}

      assert %Comment{like_count: 1, dislike_count: 0} = Repo.get!(Comment, uuid)
    end

    test "a counter never drops below the truth or below zero",
         %{comment: comment, author: author} do
      # Duplicate rows (no unique index) on a counter of 1: removing both
      # used to skip the decrement and leave 1.
      {:ok, :liked} = PhoenixKitComments.like_comment(comment.uuid, author.uuid)

      Repo.insert!(%PhoenixKitComments.CommentLike{
        comment_uuid: comment.uuid,
        user_uuid: author.uuid
      })

      assert {:ok, :unliked} = PhoenixKitComments.unlike_comment(comment.uuid, author.uuid)
      assert %Comment{like_count: 0} = Repo.get!(Comment, comment.uuid)
    end
  end

  describe "NUL bytes" do
    test "in a body, are refused before the insert", %{author: author} do
      assert {:error, :invalid_content} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), author.uuid, %{
                 content: "a\u0000b"
               })
    end

    test "in metadata, are a changeset error", %{author: author} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), author.uuid, %{
                 content: "fine",
                 metadata: %{"x" => %{"y" => "a\u0000"}}
               })

      assert {_, [validation: :null_byte]} = changeset.errors[:metadata]
    end

    test "in an edit, are a changeset error", %{comment: comment} do
      assert {:error, changeset} =
               PhoenixKitComments.update_comment(comment, %{content: "a\u0000"})

      assert {_, [validation: :null_byte]} = changeset.errors[:content]
    end

    test "in a search, are dropped", %{comment: comment} do
      assert %{comments: [%{uuid: uuid}]} =
               PhoenixKitComments.list_all_comments(
                 search: "comm\u0000ent",
                 user_uuid: comment.user_uuid
               )

      assert uuid == comment.uuid
    end
  end

  describe "list_all_comments/1" do
    test "clamps the page and page size", %{comment: comment} do
      assert %{per_page: 1, comments: [_]} =
               PhoenixKitComments.list_all_comments(per_page: 0, user_uuid: comment.user_uuid)

      assert %{per_page: 200} = PhoenixKitComments.list_all_comments(per_page: 1_000_000)
      assert %{page: 10_000, comments: []} = PhoenixKitComments.list_all_comments(page: 10 ** 20)
      assert %{page: 1} = PhoenixKitComments.list_all_comments(page: -3)
    end

    test "a malformed user filter matches nothing, not everyone", %{comment: _comment} do
      assert %{comments: [], total: 0} = PhoenixKitComments.list_all_comments(user_uuid: "nope")
    end

    test "search wildcards match literally", %{author: author} do
      literal = comment_fixture(author, %{content: "100% sure_thing"})
      _other = comment_fixture(author, %{content: "1000 sure-thing"})

      assert %{comments: [%{uuid: uuid}]} =
               PhoenixKitComments.list_all_comments(search: "100% sure_", user_uuid: author.uuid)

      assert uuid == literal.uuid
    end
  end

  describe "create_comment/4 attrs" do
    test "string keys carry the client fields only", %{author: author} do
      {:ok, _} = Settings.update_boolean_setting("comments_moderation", true)

      assert {:ok, comment} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), author.uuid, %{
                 "content" => "from a form",
                 "status" => "published",
                 "inserted_at" => ~U[2001-01-01 00:00:00Z]
               })

      assert comment.content == "from a form"
      # Forwarded params can't skip the queue or backdate the row.
      assert comment.status == "pending"
      assert comment.inserted_at.year > 2001
    after
      Settings.update_boolean_setting("comments_moderation", false)
    end

    test "a reply to a comment on another record is refused", %{author: author, comment: comment} do
      assert {:error, :invalid_parent} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), author.uuid, %{
                 content: "reply",
                 parent_uuid: comment.uuid
               })

      assert {:error, :invalid_parent} =
               PhoenixKitComments.create_comment(
                 @type_name,
                 comment.resource_uuid,
                 author.uuid,
                 %{
                   content: "reply",
                   parent_uuid: "not-a-uuid"
                 }
               )

      # The same record, spelled upper-case, is the same record.
      assert {:ok, %Comment{depth: 1}} =
               PhoenixKitComments.create_comment(
                 @type_name,
                 String.upcase(comment.resource_uuid),
                 author.uuid,
                 %{content: "reply", parent_uuid: comment.uuid}
               )
    end

    test "a nil author is an error, not a crash" do
      assert {:error, :invalid_user_uuid} =
               PhoenixKitComments.create_comment(@type_name, Ecto.UUID.generate(), nil, %{
                 content: "x"
               })

      assert {:error, :invalid_user_uuid} =
               PhoenixKitComments.precheck_create(@type_name, Ecto.UUID.generate(), nil, %{})
    end
  end

  describe "update_comment/3" do
    test "cannot move or re-sign a comment", %{comment: comment} do
      other = user_fixture()

      assert {:ok, updated} =
               PhoenixKitComments.update_comment(comment, %{
                 "content" => "edited",
                 "user_uuid" => other.uuid,
                 "resource_uuid" => Ecto.UUID.generate(),
                 "parent_uuid" => comment.uuid,
                 "depth" => -5
               })

      assert updated.content == "edited"
      assert updated.user_uuid == comment.user_uuid
      assert updated.resource_uuid == comment.resource_uuid
      assert updated.parent_uuid == nil
      assert updated.depth == 0
    end
  end

  describe "live updates" do
    test "a create reaches the lower-case topic whatever the caller's spelling",
         %{author: author} do
      resource = Ecto.UUID.generate()
      :ok = PhoenixKitComments.subscribe(@type_name, resource)

      capture_log(fn ->
        {:ok, _} =
          PhoenixKitComments.create_comment(@type_name, String.upcase(resource), author.uuid, %{
            content: "loud"
          })
      end)

      assert_receive {:comments_updated, %{action: :created, resource_uuid: ^resource}}
    end
  end

  describe "a misbehaving resource handler" do
    test "is logged without the comment it failed on", %{author: author} do
      log =
        capture_log(fn ->
          assert {:ok, _} =
                   PhoenixKitComments.create_comment(
                     @type_name,
                     Ecto.UUID.generate(),
                     author.uuid,
                     %{content: "SECRET-BODY-123"}
                   )
        end)

      assert log =~ "Comment resource handler error: FunctionClauseError"
      refute log =~ "SECRET-BODY-123"
    end
  end

  describe "get_comment_tree/2 placeholders" do
    test "a hidden parent stays, blanked, while it has a published reply",
         %{author: author, comment: parent} do
      reply =
        comment_fixture(author, %{
          resource_type: @type_name,
          resource_uuid: parent.resource_uuid,
          parent_uuid: parent.uuid,
          content: "reply"
        })

      {:ok, _} = PhoenixKitComments.hide_comment(parent)

      assert [%Comment{status: "hidden", content: "", media: [], children: [child]}] =
               PhoenixKitComments.get_comment_tree(@type_name, parent.resource_uuid)

      assert child.uuid == reply.uuid
    end

    test "a hidden comment without a published reply is not in the tree",
         %{author: author, comment: parent} do
      reply =
        comment_fixture(author, %{
          resource_type: @type_name,
          resource_uuid: parent.resource_uuid,
          parent_uuid: parent.uuid
        })

      {:ok, _} = PhoenixKitComments.delete_comment(reply)
      {:ok, _} = PhoenixKitComments.hide_comment(parent)

      # Pruned bottom-up: its only reply was a placeholder with no replies.
      assert PhoenixKitComments.get_comment_tree(@type_name, parent.resource_uuid) == []
    end
  end

  describe "status from params" do
    test "neither changeset casts it", %{comment: comment} do
      refute Map.has_key?(
               Comment.changeset(%Comment{}, %{"status" => "hidden"}).changes,
               :status
             )

      refute Map.has_key?(
               Comment.update_changeset(comment, %{"status" => "hidden"}).changes,
               :status
             )

      assert %{status: "hidden"} =
               Comment.put_status(Ecto.Changeset.change(comment), "hidden").changes

      refute Comment.put_status(Ecto.Changeset.change(comment), "gone").valid?
    end

    test "an edit forwarded with a status cannot un-hide a comment", %{comment: comment} do
      {:ok, hidden} = PhoenixKitComments.hide_comment(comment)

      assert {:ok, edited} =
               PhoenixKitComments.update_comment(hidden, %{
                 "content" => "edited",
                 "status" => "published"
               })

      assert edited.status == "hidden"
    end

    test "server code still sets it with an atom key", %{comment: comment} do
      assert {:ok, %Comment{status: "pending"}} =
               PhoenixKitComments.update_comment(comment, %{status: "pending"})
    end
  end
end
