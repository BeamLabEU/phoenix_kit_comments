defmodule PhoenixKitComments.FileReferencesTest do
  @moduledoc false
  # The schema half of the file-references contract: every column of this
  # module's schemas that points at a stored file must be declared to core's
  # orphan check. Derived from the schemas, so a new file column without a
  # declaration fails here. The database half (foreign keys, and core's
  # orphan finder itself) is `PhoenixKitComments.Integration.FileReferencesTest`.
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.File, as: StorageFile

  defp schemas do
    {:ok, modules} = :application.get_key(:phoenix_kit_comments, :modules)

    Enum.filter(modules, fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) and
        mod.__schema__(:source) != nil
    end)
  end

  # `{table, column}` for each `belongs_to` a stored file.
  defp file_columns do
    for schema <- schemas(),
        assoc <- schema.__schema__(:associations),
        %Ecto.Association.BelongsTo{related: StorageFile, owner_key: key} <-
          [schema.__schema__(:association, assoc)] do
      {schema.__schema__(:source), Atom.to_string(key)}
    end
  end

  test "the module exports file_references/0 as a PhoenixKit.Module callback" do
    Code.ensure_loaded!(PhoenixKitComments)
    assert function_exported?(PhoenixKitComments, :file_references, 0)
    assert {:file_references, 0} in PhoenixKit.Module.behaviour_info(:callbacks)
  end

  test "comment media is a file reference (guards the derivation below)" do
    assert {"phoenix_kit_comment_media", "file_uuid"} in file_columns()
  end

  test "every file column of the module's schemas is declared" do
    declared = PhoenixKitComments.file_references()

    for {table, column} <- file_columns() do
      conditions = for {^table, condition} <- declared, do: inspect(condition)

      assert conditions != [],
             "#{table}.#{column} references phoenix_kit_files but #{table} is not in file_references/0"

      assert Enum.any?(conditions, &String.contains?(&1, column)),
             "#{table} is declared but no condition names #{column}"
    end
  end

  test "core accepts the declaration" do
    assert {:ok, pairs} = PhoenixKit.ModuleRegistry.file_reference_pairs(PhoenixKitComments)
    assert pairs != []
  end
end
