defmodule PhoenixKitComments.Integration.PublishedMarkTest do
  @moduledoc """
  `metadata["published_once"]` is server-owned: a later publication sets it
  and nothing clears it. `update_comment/3` reads the mark from the ROW under
  its lock, never from the struct the caller holds (kimi, 2026-11-25: an
  edit on a struct read before an approval wrote `false` back, and the next
  hide + approve announced the comment again). A restore that publishes a
  comment for the first time tells the handler like an approval does.
  """

  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKitComments.Comment

  defmodule Handler do
    @moduledoc false
    @behaviour PhoenixKitComments.ResourceHandler

    @impl true
    def on_comment_published(type, uuid, comment),
      do: send(:persistent_term.get({__MODULE__, :pid}), {:published, type, uuid, comment.uuid})
  end

  setup do
    :persistent_term.put({Handler, :pid}, self())
    previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)
    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{"mark_probe" => Handler})

    on_exit(fn ->
      :persistent_term.erase({Handler, :pid})

      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
    end)

    %{author: user_fixture()}
  end

  test "a metadata edit on a stale struct cannot un-publish the mark", %{author: author} do
    key = Comment.published_key()

    {:ok, comment} =
      PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
        "content" => "held for review",
        status: "pending"
      })

    assert comment.metadata[key] == false

    # The moderator approves; the row now says published-once.
    {:ok, approved} = PhoenixKitComments.approve_comment(comment)
    assert approved.metadata[key] == true
    assert_received {:published, "mark_probe", _, _}

    # The author's session still holds the PRE-approval struct and edits
    # the comment's metadata (a host's decoration write, a retitle).
    {:ok, edited} =
      PhoenixKitComments.update_comment(comment, %{"metadata" => %{"note" => "edited"}})

    assert edited.status == "published"
    assert edited.metadata["note"] == "edited"

    assert edited.metadata[key] == true,
           "the mark was cleared by a metadata edit on a stale struct"

    # And so the next hide + approve must stay silent.
    {:ok, hidden} = PhoenixKitComments.hide_comment(Repo.get!(Comment, comment.uuid))
    {:ok, _} = PhoenixKitComments.approve_comment(hidden)

    refute_received {:published, _, _, _}
  end

  test "an edit reports a comment removed since it was read", %{author: author} do
    comment = comment_fixture(author)
    Repo.delete!(comment)
    assert {:error, :not_found} = PhoenixKitComments.update_comment(comment, %{content: "edited"})
  end

  test "a server-side edit that publishes calls the handler once", %{author: author} do
    {:ok, held} =
      PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
        content: "held",
        status: "pending"
      })

    assert {:ok, published} = PhoenixKitComments.update_comment(held, %{status: "published"})
    assert published.status == "published"
    assert_received {:published, _, _, _}
    assert {:ok, _} = PhoenixKitComments.update_comment(held, %{status: "published"})
    refute_received {:published, _, _, _}
  end

  test "metadata replacements and patches preserve publication history", %{author: author} do
    comment = comment_fixture(author)
    key = Comment.published_key()

    assert {:ok, edited} = PhoenixKitComments.update_comment(comment, %{"metadata" => nil})
    assert edited.metadata == %{key => true}

    assert {:ok, patched} =
             PhoenixKitComments.update_metadata(comment, %{published_once: false, slug: "old"})

    assert patched.metadata == %{key => true, "slug" => "old"}

    assert PhoenixKitComments.merge_metadata(comment.resource_type, %{"slug" => "old"}, %{
             key => false,
             "slug" => "new"
           }) == 1

    assert Repo.get!(Comment, comment.uuid).metadata == %{key => true, "slug" => "new"}
  end

  # Rows from before the mark existed carry none (zai, 2026-11-26): their
  # first status change records what that status says — leaving "published"
  # means it was published, leaving "pending" means it was not — so the
  # later publication goes by the mark, not by a guess from the status.
  describe "a comment from before the mark" do
    setup do
      on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("comments_moderation", false) end)
      :ok
    end

    defp strip_mark(comment) do
      import Ecto.Query
      meta = Map.delete(comment.metadata || %{}, Comment.published_key())

      Repo.update_all(from(c in Comment, where: c.uuid == ^comment.uuid), set: [metadata: meta])

      Repo.get!(Comment, comment.uuid)
    end

    test "held, hidden, then approved: announced on that first publication", %{author: author} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "held before the upgrade",
          status: "pending"
        })

      legacy = strip_mark(comment)
      {:ok, hidden} = PhoenixKitComments.hide_comment(legacy)
      {:ok, approved} = PhoenixKitComments.approve_comment(Repo.get!(Comment, hidden.uuid))

      assert approved.status == "published"
      assert_received {:published, "mark_probe", _, _}
    end

    test "held, deleted, then restored published: announced", %{author: author} do
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", true)

      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "held before the upgrade"
        })

      legacy = strip_mark(comment)
      {:ok, deleted} = PhoenixKitComments.delete_comment(legacy)
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", false)
      {:ok, restored} = PhoenixKitComments.restore_comment(Repo.get!(Comment, deleted.uuid))

      assert restored.status == "published"
      assert_received {:published, "mark_probe", _, _}
    end

    test "published, re-queued, then approved: not announced again", %{author: author} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "published before the upgrade"
        })

      legacy = strip_mark(comment)
      assert legacy.status == "published"
      PhoenixKitComments.bulk_update_status([legacy.uuid], "pending")
      requeued = Repo.get!(Comment, legacy.uuid)
      assert requeued.status == "pending"
      {:ok, _} = PhoenixKitComments.approve_comment(requeued)

      refute_received {:published, _, _, _}
    end
  end

  describe "restore" do
    setup do
      on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("comments_moderation", false) end)
      :ok
    end

    test "a held comment deleted and restored published is announced, once", %{author: author} do
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", true)

      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "held, then deleted"
        })

      assert comment.status == "pending"
      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)

      PhoenixKit.Settings.update_boolean_setting("comments_moderation", false)
      {:ok, restored} = PhoenixKitComments.restore_comment(deleted)

      assert restored.status == "published"
      assert restored.metadata[Comment.published_key()] == true
      assert_received {:published, "mark_probe", _, _}

      {:ok, hidden} = PhoenixKitComments.hide_comment(restored)
      {:ok, _} = PhoenixKitComments.approve_comment(hidden)
      refute_received {:published, _, _, _}
    end

    test "a published comment deleted and restored is not announced again", %{author: author} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "born published"
        })

      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)
      {:ok, restored} = PhoenixKitComments.restore_comment(deleted)

      assert restored.status == "published"
      refute_received {:published, _, _, _}
    end

    test "a restore back to pending tells nobody yet", %{author: author} do
      PhoenixKit.Settings.update_boolean_setting("comments_moderation", true)

      {:ok, comment} =
        PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "held"
        })

      {:ok, deleted} = PhoenixKitComments.delete_comment(comment)
      {:ok, restored} = PhoenixKitComments.restore_comment(deleted)

      assert restored.status == "pending"
      refute_received {:published, _, _, _}
    end
  end
end
