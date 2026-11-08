defmodule PhoenixKitComments.Integration.EmptyAnchorCommentsTest do
  @moduledoc """
  PR #37 added `:allow_empty_content` to `create_comment/4` for server-created
  anchor comments whose visible text lives elsewhere, but shipped with no
  coverage. These pin the contract: `true` skips the content-or-media
  requirement, anything else still enforces it, and the escape hatch doesn't
  leak into `precheck_create/5` or into later edits of the same comment.
  """
  use PhoenixKitComments.DataCase, async: true

  alias PhoenixKitComments.Test.Repo

  setup do
    {:ok, user: user_fixture()}
  end

  describe "allow_empty_content: true" do
    test "creates a comment with no content, GIF, or media", %{user: user} do
      {:ok, comment} =
        PhoenixKitComments.create_comment(
          "test_resource",
          Ecto.UUID.generate(),
          user.uuid,
          %{allow_empty_content: true}
        )

      assert comment.content == ""

      reloaded = Repo.get(PhoenixKitComments.Comment, comment.uuid)
      assert reloaded.content == ""
    end

    test "precheck_create/5 also allows the empty body", %{user: user} do
      assert :ok =
               PhoenixKitComments.precheck_create(
                 "test_resource",
                 Ecto.UUID.generate(),
                 user.uuid,
                 %{allow_empty_content: true}
               )
    end
  end

  describe "without allow_empty_content" do
    test "an empty comment is still rejected", %{user: user} do
      assert {:error, :empty_comment} =
               PhoenixKitComments.create_comment(
                 "test_resource",
                 Ecto.UUID.generate(),
                 user.uuid,
                 %{}
               )
    end

    test "a falsy value does not open the escape hatch", %{user: user} do
      assert {:error, :empty_comment} =
               PhoenixKitComments.create_comment(
                 "test_resource",
                 Ecto.UUID.generate(),
                 user.uuid,
                 %{allow_empty_content: false}
               )
    end
  end

  describe "editing an empty anchor comment" do
    test "filling in real content later still requires a non-empty body if cleared again", %{
      user: user
    } do
      {:ok, comment} =
        PhoenixKitComments.create_comment(
          "test_resource",
          Ecto.UUID.generate(),
          user.uuid,
          %{allow_empty_content: true}
        )

      assert {:ok, edited} = PhoenixKitComments.update_comment(comment, %{content: "now filled"})
      assert edited.content == "now filled"

      assert {:error, changeset} = PhoenixKitComments.update_comment(edited, %{content: ""})

      assert {"can't be blank without a GIF or attachment", [validation: :content_or_media]} =
               changeset.errors[:content]
    end
  end
end
