defmodule PhoenixKitComments.AttachmentsTest do
  @moduledoc false
  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitComments.Attachments

  defmodule Hook do
    @moduledoc false
    def parent(:comment_attachment, _actor, %{resource_type: "order", resource_uuid: uuid}) do
      {:ok, Process.get({:folder_for, uuid})}
    end

    def parent(:comment_attachment, _actor, _subject), do: nil
  end

  defmodule RaisingHook do
    @moduledoc false
    def parent(:comment_attachment, _actor, _subject), do: raise("boom")
  end

  # A host hook that calls a process which is not there exits rather than
  # raising — the shape `rescue` alone does not cover.
  defmodule ExitingHook do
    @moduledoc false
    def parent(:comment_attachment, _actor, _subject) do
      GenServer.call(:no_such_media_folder_server, {:parent, :comment_attachment})
    end
  end

  # The documented 2-arity form: no subject, so one folder for everything.
  defmodule TwoArityHook do
    @moduledoc false
    def parent(:comment_attachment, _actor), do: {:ok, Process.get(:folder_for_all)}
  end

  # A hook that answers a uuid for a folder that no longer exists (deleted
  # since the host cached it), or something that is not a uuid at all.
  defmodule StaleHook do
    @moduledoc false
    def parent(:comment_attachment, _actor, _subject), do: {:ok, Process.get(:stale_answer)}
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_comments, :attachments_parent_folder) end)
    :ok
  end

  defp folder_fixture! do
    {:ok, folder} = Storage.create_folder(%{name: "folder-#{System.unique_integer([:positive])}"})
    folder
  end

  # A root file (`folder_uuid: nil`), inserted directly rather than through
  # `Storage.store_file/2` — that call writes to disk and manages buckets,
  # infra this module doesn't otherwise need. Mirrors what core would have
  # persisted for a small upload.
  defp root_file_fixture! do
    n = System.unique_integer([:positive])
    checksum = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    %Storage.File{}
    |> Ecto.Changeset.change(%{
      original_file_name: "attachment-#{n}.png",
      file_name: "attachment-#{n}.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: checksum,
      user_file_checksum: checksum,
      size: 1024,
      status: "active",
      user_uuid: user_fixture().uuid
    })
    |> Repo.insert!()
  end

  test "hook returning a folder places the file there" do
    order_uuid = Ecto.UUID.generate()
    folder = folder_fixture!()
    Process.put({:folder_for, order_uuid}, folder.uuid)
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {Hook, :parent})

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", order_uuid, nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == folder.uuid
  end

  test "without config the file stays where store_file put it" do
    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end

  test "a raising hook is swallowed and the file is left untouched" do
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {RaisingHook, :parent})

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end

  test "an unresolved resource type is a no-op" do
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {Hook, :parent})

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "crm_company", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end

  test "the 2-arity hook form is honoured" do
    folder = folder_fixture!()
    Process.put(:folder_for_all, folder.uuid)

    Application.put_env(
      :phoenix_kit_comments,
      :attachments_parent_folder,
      {TwoArityHook, :parent}
    )

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == folder.uuid
  end

  test "a hook that exits is swallowed and the file is left untouched" do
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {ExitingHook, :parent})

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end

  # This runs inside `consume_uploaded_entries/3`: a raise here crashes the
  # component after the files are stored, and the comment is lost.
  test "a folder uuid that no longer exists does not raise" do
    Process.put(:stale_answer, Ecto.UUID.generate())
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {StaleHook, :parent})

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(file, "order", Ecto.UUID.generate(), nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end

  test "a non-uuid answer is treated as no answer" do
    Process.put(:stale_answer, "not-a-uuid")
    Application.put_env(:phoenix_kit_comments, :attachments_parent_folder, {StaleHook, :parent})

    assert Attachments.parent_folder_uuid("order", Ecto.UUID.generate(), nil) == nil
  end

  test "a map with only a uuid is loaded before placing" do
    folder = folder_fixture!()
    Process.put(:folder_for_all, folder.uuid)

    Application.put_env(
      :phoenix_kit_comments,
      :attachments_parent_folder,
      {TwoArityHook, :parent}
    )

    file = root_file_fixture!()

    assert :ok = Attachments.place_stored_file(%{uuid: file.uuid}, "order", "x", nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == folder.uuid
  end

  test "place_file/2 with no folder is a no-op" do
    file = root_file_fixture!()

    assert :ok = Attachments.place_file(file, nil)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == nil
  end
end
