defmodule PhoenixKitComments.Attachments do
  @moduledoc """
  Where comment attachments are stored. By default `Storage.store_file/2`
  leaves them at the media root; a host can place them next to the
  commented record:

      config :phoenix_kit_comments, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:comment_attachment, actor_uuid, %{resource_type: type, resource_uuid: uuid})`
  (or `parent_for(:comment_attachment, actor_uuid)`), returning `{:ok, folder_uuid}` or `nil`.

  The component asks once per comment and places every file of that comment
  with the answer. The hook contract and the placing rule are core's
  `PhoenixKit.Modules.Storage.ResourceFolders`, so nothing here raises or
  exits into the caller: it runs inside `consume_uploaded_entries/3`, after
  the files are already stored, so a crash would lose the comment and keep
  its uploads.
  """
  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ResourceFolders

  @kind :comment_attachment

  @doc """
  Asks the host hook where attachments for `resource_type`/`resource_uuid`
  should live. `nil` (no config, no clause, a `nil` or non-uuid answer, or
  the hook raising, throwing or exiting) means "leave it at the media root"
  — the default behaviour.
  """
  @spec parent_folder_uuid(String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def parent_folder_uuid(resource_type, resource_uuid, actor_uuid) do
    ResourceFolders.parent_uuid(:phoenix_kit_comments, @kind, actor_uuid, %{
      resource_type: resource_type,
      resource_uuid: resource_uuid
    })
  end

  @doc """
  Puts a just-stored file into `folder_uuid` (an answer from
  `parent_folder_uuid/3`) by core's attach rule: a homeless file is adopted,
  a file homed elsewhere gains a folder link. `nil` is a no-op, and so is a
  folder deleted or trashed since the host answered. Always `:ok`; a failure
  is logged and the file stays where storage put it.
  """
  @spec place_file(Storage.File.t() | %{uuid: String.t()}, String.t() | nil) :: :ok
  def place_file(_file, nil), do: :ok

  def place_file(%{uuid: file_uuid} = file, folder_uuid) when is_binary(folder_uuid) do
    file = if match?(%Storage.File{}, file), do: file, else: file_uuid

    case ResourceFolders.attach(file, folder_uuid) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Comments] could not place file #{file_uuid}: " <>
            ResourceFolders.describe_failure(reason)
        )

        :ok
    end
  end

  @doc "`place_file/2` with the folder asked from the hook for this one file."
  @spec place_stored_file(
          Storage.File.t() | %{uuid: String.t()},
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          :ok
  def place_stored_file(file, resource_type, resource_uuid, actor_uuid) do
    place_file(file, parent_folder_uuid(resource_type, resource_uuid, actor_uuid))
  end
end
