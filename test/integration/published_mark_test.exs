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

    assert edited.metadata["note"] == "edited"

    assert edited.metadata[key] == true,
           "the mark was cleared by a metadata edit on a stale struct"

    # And so the next hide + approve must stay silent.
    {:ok, hidden} = PhoenixKitComments.hide_comment(Repo.get!(Comment, comment.uuid))
    {:ok, _} = PhoenixKitComments.approve_comment(hidden)

    refute_received {:published, _, _, _}
  end

  test "a stale edit then hide + approve announces the comment once only", %{author: author} do
    {:ok, comment} =
      PhoenixKitComments.create_comment("mark_probe", Ecto.UUID.generate(), author.uuid, %{
        "content" => "held for review",
        status: "pending"
      })

    {:ok, _approved} = PhoenixKitComments.approve_comment(comment)
    assert_received {:published, "mark_probe", _, _}

    {:ok, _} = PhoenixKitComments.update_comment(comment, %{"metadata" => %{"note" => "x"}})
    {:ok, hidden} = PhoenixKitComments.hide_comment(Repo.get!(Comment, comment.uuid))
    {:ok, _} = PhoenixKitComments.approve_comment(hidden)

    refute_received {:published, _, _, _}
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
