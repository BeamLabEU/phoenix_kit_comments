defmodule PhoenixKitComments.Integration.FileReferencesTest do
  @moduledoc false
  # Core 3.0's built-in orphan check no longer covers this module's tables, so
  # without `file_references/0` every comment attachment is listed as an
  # orphan and "Delete all orphaned" trashes it. These run core's own finder.
  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKit.Migrations.ModuleOwnedTables
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitComments.CommentMedia

  # Inserted directly, as in `AttachmentsTest`: `Storage.store_file/2` writes
  # to disk and manages buckets.
  defp file_fixture!(user) do
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
      user_uuid: user.uuid
    })
    |> Repo.insert!()
  end

  # The media row written directly: attachments are off by default, and the
  # reference is the row, however it got there.
  defp attach!(user, file) do
    {:ok, comment} =
      PhoenixKitComments.create_comment("post", Ecto.UUID.generate(), user.uuid, %{
        content: "see attached"
      })

    %CommentMedia{}
    |> CommentMedia.changeset(%{
      comment_uuid: comment.uuid,
      file_uuid: file.uuid,
      position: 1
    })
    |> Repo.insert!()

    comment
  end

  test "the registry hands core this module's references" do
    assert {:ok, [_ | _]} =
             Map.fetch!(ModuleRegistry.all_file_references(), :phoenix_kit_comments)
  end

  test "an attached file is not an orphan; an unattached one is" do
    user = user_fixture()
    attached = file_fixture!(user)
    loose = file_fixture!(user)
    attach!(user, attached)

    refute Storage.file_orphaned?(attached.uuid)
    assert Storage.file_orphaned?(loose.uuid)

    orphans = Storage.find_orphaned_files() |> Enum.map(& &1.uuid)
    refute attached.uuid in orphans
    assert loose.uuid in orphans
  end

  test "a soft-deleted comment still holds its attachment" do
    user = user_fixture()
    file = file_fixture!(user)
    comment = attach!(user, file)

    {:ok, _} = PhoenixKitComments.delete_comment(comment)

    refute Storage.file_orphaned?(file.uuid)
  end

  test "without the declaration core takes the attachment for an orphan" do
    # What a core 3.0 site does today with a module version that predates
    # the callback: proves the test above is not passing for another reason.
    user = user_fixture()
    file = file_fixture!(user)
    attach!(user, file)

    without = Storage.orphaned_files_query(%{})
    with_ours = Storage.orphaned_files_query(ModuleRegistry.all_file_references())

    assert Repo.exists?(where(without, [f], f.uuid == ^file.uuid))
    refute Repo.exists?(where(with_ours, [f], f.uuid == ^file.uuid))
  end

  test "every foreign key from this module's tables to the files table is declared" do
    # The tables core records as ours, plus every table a schema of ours maps
    # (a table this module adds later is in the second list only).
    {:ok, modules} = :application.get_key(:phoenix_kit_comments, :modules)

    schema_tables =
      for mod <- modules,
          Code.ensure_loaded?(mod),
          function_exported?(mod, :__schema__, 1),
          do: mod.__schema__(:source)

    tables =
      Enum.uniq(
        ModuleOwnedTables.tables_for(:phoenix_kit_comments) ++
          schema_tables
      )

    %{rows: rows} =
      Repo.query!(
        """
        SELECT cl.relname, a.attname
        FROM pg_constraint c
        JOIN pg_class cl ON cl.oid = c.conrelid
        JOIN pg_class ref ON ref.oid = c.confrelid
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
        WHERE c.contype = 'f' AND ref.relname = 'phoenix_kit_files'
          AND cl.relname = ANY($1)
        """,
        [tables]
      )

    assert rows != [], "expected at least phoenix_kit_comment_media.file_uuid"
    declared = PhoenixKitComments.file_references()

    for [table, column] <- rows do
      conditions = for {^table, condition} <- declared, do: inspect(condition)

      assert Enum.any?(conditions, &String.contains?(&1, column)),
             "#{table}.#{column} references phoenix_kit_files but is not declared"
    end
  end
end
