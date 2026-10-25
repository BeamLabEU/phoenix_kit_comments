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

  defp comment_with_status(author, resource_uuid, status) do
    {:ok, comment} =
      PhoenixKitComments.create_comment("approve_probe", resource_uuid, author.uuid, %{
        content: "a comment"
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
    b = comment_with_status(author, Ecto.UUID.generate(), "hidden")

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
    comment = comment_with_status(author, Ecto.UUID.generate(), "published")
    Repo.update_all(from(c in Comment, where: c.uuid == ^comment.uuid), set: [status: "pending"])

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
end
