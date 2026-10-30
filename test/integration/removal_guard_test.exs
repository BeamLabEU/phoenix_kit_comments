defmodule PhoenixKitComments.Integration.RemovalGuardTest do
  @moduledoc false
  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitComments.{CommentMedia, RemovalGuard}

  defp file_fixture!(user) do
    n = System.unique_integer([:positive])
    checksum = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    %Storage.File{}
    |> Ecto.Changeset.change(%{
      original_file_name: "guard-#{n}.png",
      file_name: "guard-#{n}.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: checksum,
      user_file_checksum: checksum,
      size: 1024,
      status: "active",
      user_uuid: user.uuid
    })
    |> Repo.insert!()
  end

  defp attach!(user, file, resource_type \\ "post") do
    {:ok, comment} =
      PhoenixKitComments.create_comment(resource_type, Ecto.UUID.generate(), user.uuid, %{
        content: "see attached"
      })

    %CommentMedia{}
    |> CommentMedia.changeset(%{comment_uuid: comment.uuid, file_uuid: file.uuid, position: 1})
    |> Repo.insert!()

    comment
  end

  defp ctx(keys) do
    scope = %Scope{
      user: nil,
      authenticated?: true,
      cached_permissions: MapSet.new(keys)
    }

    %{scope: scope, action: :trash_file, folder_uuid: nil}
  end

  test "no files, no places" do
    assert RemovalGuard.places([], ctx(["comments"])) == []
  end

  test "a file no comment shows has no place" do
    user = user_fixture()
    loose = file_fixture!(user)

    assert RemovalGuard.places([loose.uuid], ctx(["comments"])) == []
  end

  test "a file a comment shows is in use, and only that file" do
    user = user_fixture()
    used = file_fixture!(user)
    loose = file_fixture!(user)
    attach!(user, used, "product")

    assert [%{file_uuid: uuid, label: label, detail: detail, href: nil}] =
             RemovalGuard.places([used.uuid, loose.uuid], ctx(["comments"]))

    assert uuid == used.uuid
    assert label =~ "comment"
    assert detail =~ "product"
  end

  test "only the files asked about are answered" do
    user = user_fixture()
    asked = file_fixture!(user)
    other = file_fixture!(user)
    attach!(user, asked)
    attach!(user, other)

    assert [%{file_uuid: uuid}] = RemovalGuard.places([asked.uuid], ctx(["comments"]))
    assert uuid == asked.uuid
  end

  test "a file shown by two comments is listed once" do
    user = user_fixture()
    file = file_fixture!(user)
    attach!(user, file)
    attach!(user, file)

    assert [_one] = RemovalGuard.places([file.uuid], ctx(["comments"]))
  end

  test "a soft-deleted comment still holds its file" do
    user = user_fixture()
    file = file_fixture!(user)
    comment = attach!(user, file)
    {:ok, _} = PhoenixKitComments.delete_comment(comment)

    assert [_] = RemovalGuard.places([file.uuid], ctx(["comments"]))
  end

  test "a person without comments access gets a place they cannot see" do
    user = user_fixture()
    file = file_fixture!(user)
    attach!(user, file, "secret_thing")

    assert [%{label: nil, detail: nil, href: nil}] =
             RemovalGuard.places([file.uuid], ctx(["media"]))

    assert [%{label: nil}] = RemovalGuard.places([file.uuid], %{scope: nil})
  end

  test "it satisfies core's behaviour without release" do
    Code.ensure_loaded!(RemovalGuard)
    assert function_exported?(RemovalGuard, :places, 2)
    refute function_exported?(RemovalGuard, :release, 2)
  end
end
