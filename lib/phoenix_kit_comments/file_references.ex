defmodule PhoenixKitComments.FileReferences do
  @moduledoc """
  The places in this module's tables that point at a stored file, for the
  orphan-file check of core's storage (`PhoenixKit.Module.file_references/0`).

  A file one of these rows names is a comment's attachment and must never be
  read as an orphan: core would list it under "Orphaned files" and "Delete all
  orphaned" would trash it, leaving the comment with a dead attachment. Each
  pair is a table and the condition "this table does not reference the file";
  core leaves the pair out when the table does not exist.

  Core 3.0's built-in list no longer covers `phoenix_kit_comment_media`, so this
  declaration is the only thing that protects comment attachments there.

  Every column of this module's tables that names a `phoenix_kit_files` row
  belongs in this list. `test/phoenix_kit_comments/file_references_test.exs`
  derives the columns from the schemas and the foreign keys and fails when one
  is missing.
  """

  import Ecto.Query, only: [dynamic: 2]

  @spec pairs() :: [{String.t(), Ecto.Query.dynamic_expr()}]
  def pairs do
    [
      # A soft-deleted comment keeps its media rows (it can be restored), so
      # its files stay referenced too.
      {"phoenix_kit_comment_media",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_comment_media cm WHERE cm.file_uuid = ?)",
           f.uuid
         )
       )}
    ]
  end
end
