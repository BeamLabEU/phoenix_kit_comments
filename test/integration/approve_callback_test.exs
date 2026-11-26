defmodule PhoenixKitComments.Integration.ApproveCallbackTest do
  @moduledoc """
  A comment held for moderation reaches its readers when it is approved,
  so the owning module's handler hears of it then — once — through
  `on_comment_published/3`. Without it a moderated comment told nobody.
  """

  use PhoenixKitComments.DataCase, async: false

  import Ecto.Query

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
    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{"approve_probe" => Handler})

    on_exit(fn ->
      :persistent_term.erase({Handler, :pid})

      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
    end)

    %{author: user_fixture()}
  end

  # Born `born` (as moderation would make it), then moved to `status` in the
  # database. Whether a comment was ever published is part of what it is: a
  # comment born pending and one born published differ at approval.
  defp comment_with_status(author, resource_uuid, status, born \\ "pending") do
    {:ok, comment} =
      PhoenixKitComments.create_comment("approve_probe", resource_uuid, author.uuid, %{
        content: "a comment",
        status: born
      })

    {1, _} =
      Repo.update_all(from(c in Comment, where: c.uuid == ^comment.uuid), set: [status: status])

    Repo.get!(Comment, comment.uuid)
  end

  test "approving a pending comment tells the handler once", %{author: author} do
    resource = Ecto.UUID.generate()
    comment = comment_with_status(author, resource, "pending")

    {:ok, _} = PhoenixKitComments.approve_comment(comment)
    comment_uuid = comment.uuid
    assert_received {:published, "approve_probe", ^resource, ^comment_uuid}

    # Approving it again is not news.
    {:ok, _} = PhoenixKitComments.approve_comment(Repo.get!(Comment, comment.uuid))
    refute_received {:published, _, _, _}
  end

  test "bulk approval tells the handler for each pending comment", %{author: author} do
    a = comment_with_status(author, Ecto.UUID.generate(), "pending")
    # Published once, hidden since: its readers were told the first time.
    b = comment_with_status(author, Ecto.UUID.generate(), "hidden", "published")

    PhoenixKitComments.bulk_approve([a.uuid, b.uuid])

    a_uuid = a.uuid
    assert_received {:published, _, _, ^a_uuid}
    refute_received {:published, _, _, _}
  end

  test "retrying with the same pending struct does not notify again", %{author: author} do
    comment = comment_with_status(author, Ecto.UUID.generate(), "pending")

    assert {:ok, _} = PhoenixKitComments.approve_comment(comment)
    assert_received {:published, _, _, _}

    assert {:ok, _} = PhoenixKitComments.approve_comment(comment)
    refute_received {:published, _, _, _}
  end

  test "approval uses the stored pending status even if the struct says published", %{
    author: author
  } do
    pending = comment_with_status(author, Ecto.UUID.generate(), "pending")
    comment = %{pending | status: "published"}

    assert {:ok, approved} = PhoenixKitComments.approve_comment(comment)
    assert approved.status == "published"
    assert Repo.get!(Comment, comment.uuid).status == "published"
    assert_received {:published, _, _, _}
  end

  test "a stale pending struct cannot approve a comment deleted since it was loaded", %{
    author: author
  } do
    comment = comment_with_status(author, Ecto.UUID.generate(), "pending")
    assert {:ok, _} = PhoenixKitComments.delete_comment(comment)

    assert {:error, :comment_deleted} = PhoenixKitComments.approve_comment(comment)
    assert Repo.get!(Comment, comment.uuid).status == "deleted"
    refute_received {:published, _, _, _}
  end

  test "failed approval neither broadcasts nor logs nor calls the handler", %{author: author} do
    comment = comment_with_status(author, Ecto.UUID.generate(), "deleted")
    PhoenixKitComments.subscribe(comment.resource_type, comment.resource_uuid)

    assert {:error, :comment_deleted} = PhoenixKitComments.approve_comment(comment)
    refute_received {:published, _, _, _}
    refute_received {:comments_updated, _}

    PhoenixKitComments.ActivityLogAssertions.refute_activity_logged("comments.comment_approved",
      resource_uuid: comment.uuid
    )
  end

  test "approval keeps broadcast and audit options", %{author: author} do
    comment = comment_with_status(author, Ecto.UUID.generate(), "pending")
    PhoenixKitComments.subscribe(comment.resource_type, comment.resource_uuid)

    assert {:ok, _} = PhoenixKitComments.approve_comment(comment, broadcast: false, log: false)
    assert_received {:published, _, _, _}
    refute_received {:comments_updated, _}

    PhoenixKitComments.ActivityLogAssertions.refute_activity_logged("comments.comment_approved",
      resource_uuid: comment.uuid
    )
  end

  describe "the first publication, whatever the path" do
    test "held, then hidden, then approved tells the handler once", %{author: author} do
      comment = comment_with_status(author, Ecto.UUID.generate(), "pending")
      {:ok, hidden} = PhoenixKitComments.hide_comment(comment)

      {:ok, _} = PhoenixKitComments.approve_comment(hidden)
      uuid = comment.uuid
      assert_received {:published, _, _, ^uuid}

      {:ok, again} = PhoenixKitComments.hide_comment(Repo.get!(Comment, uuid))
      {:ok, _} = PhoenixKitComments.approve_comment(again)
      refute_received {:published, _, _, _}
    end

    test "published, hidden, approved again is not news", %{author: author} do
      comment = comment_with_status(author, Ecto.UUID.generate(), "published", "published")
      {:ok, hidden} = PhoenixKitComments.hide_comment(comment)

      {:ok, _} = PhoenixKitComments.approve_comment(hidden)
      refute_received {:published, _, _, _}
    end

    test "a comment born published is never announced by an approval", %{author: author} do
      comment = comment_with_status(author, Ecto.UUID.generate(), "pending", "published")

      {:ok, _} = PhoenixKitComments.approve_comment(comment)
      refute_received {:published, _, _, _}
    end

    test "the mark is the server's: a client's metadata cannot reset it", %{author: author} do
      key = Comment.published_key()
      comment = comment_with_status(author, Ecto.UUID.generate(), "published", "published")
      assert comment.metadata[key] == true

      {:ok, edited} =
        PhoenixKitComments.update_comment(comment, %{"metadata" => %{key => false, "x" => "y"}})

      assert edited.metadata[key] == true
      assert edited.metadata["x"] == "y"

      {:ok, forged} =
        PhoenixKitComments.create_comment("approve_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "forged",
          "metadata" => %{key => true}
        })

      # Born published (moderation off): true by the server's own reckoning;
      # born pending, the forged `true` is replaced.
      assert forged.metadata[key] == (forged.status == "published")

      {:ok, held} =
        PhoenixKitComments.create_comment("approve_probe", Ecto.UUID.generate(), author.uuid, %{
          "content" => "held",
          "metadata" => %{key => true},
          status: "pending"
        })

      assert held.metadata[key] == false
    end

    test "a comment from before the mark: pending counts as first, hidden does not", %{
      author: author
    } do
      key = Comment.published_key()

      legacy = fn status ->
        c = comment_with_status(author, Ecto.UUID.generate(), status, "pending")

        {1, _} =
          Repo.update_all(from(x in Comment, where: x.uuid == ^c.uuid),
            set: [metadata: Map.delete(c.metadata, key)]
          )

        Repo.get!(Comment, c.uuid)
      end

      pending = legacy.("pending")
      {:ok, _} = PhoenixKitComments.approve_comment(pending)
      pending_uuid = pending.uuid
      assert_received {:published, _, _, ^pending_uuid}

      hidden = legacy.("hidden")
      {:ok, _} = PhoenixKitComments.approve_comment(hidden)
      refute_received {:published, _, _, _}
    end
  end
end
