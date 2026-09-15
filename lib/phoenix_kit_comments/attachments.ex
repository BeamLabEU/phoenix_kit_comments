defmodule PhoenixKitComments.Attachments do
  @moduledoc """
  Where comment attachments are stored. By default `Storage.store_file/2`
  leaves them at the media root; a host can place them next to the
  commented record:

      config :phoenix_kit_comments, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:comment_attachment, actor_uuid, %{resource_type: type, resource_uuid: uuid})`
  (or `parent_for(:comment_attachment, actor_uuid)`), returning `{:ok, folder_uuid}` or `nil`.

  The component asks once per comment and places every file of that comment
  with the answer. Nothing here raises or exits into the caller: it runs
  inside `consume_uploaded_entries/3`, after the files are already stored,
  so a crash would lose the comment and keep its uploads.
  """
  require Logger
  alias PhoenixKit.Modules.Storage

  @kind :comment_attachment

  @doc """
  Asks the host hook where attachments for `resource_type`/`resource_uuid`
  should live. `nil` (no config, no clause, a `nil` or non-uuid answer, or
  the hook raising or exiting) means "leave it at the media root" — the
  default behaviour.
  """
  @spec parent_folder_uuid(String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def parent_folder_uuid(resource_type, resource_uuid, actor_uuid) do
    subject = %{resource_type: resource_type, resource_uuid: resource_uuid}

    case Application.get_env(:phoenix_kit_comments, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        mod |> call_hook(fun, actor_uuid, subject) |> folder_answer()

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("[Comments] parent folder hook failed: #{inspect(error)}")
      nil
  catch
    # A hook doing a `GenServer.call` against a dead or slow process exits
    # rather than raising. The reason carries the call arguments, so only
    # its shape is logged.
    :exit, reason ->
      Logger.warning(
        "[Comments] parent folder hook exited: #{PhoenixKitComments.describe_exit(reason)}"
      )

      nil
  end

  defp call_hook(mod, fun, actor_uuid, subject) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        apply(mod, fun, [@kind, actor_uuid, subject])

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        apply(mod, fun, [@kind, actor_uuid])

      true ->
        nil
    end
  end

  # A non-uuid binary would otherwise reach a uuid column and raise a cast
  # error at placement time.
  defp folder_answer({:ok, uuid}) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp folder_answer(_other), do: nil

  @doc """
  Puts a just-stored file into `folder_uuid` (an answer from
  `parent_folder_uuid/3`) by core's attach rule: a homeless file is adopted,
  a file homed elsewhere gains a folder link. `nil` is a no-op. Always `:ok`;
  a failure is logged and the file stays where storage put it.
  """
  @spec place_file(Storage.File.t() | %{uuid: String.t()}, String.t() | nil) :: :ok
  def place_file(_file, nil), do: :ok

  def place_file(%{uuid: file_uuid} = file, folder_uuid) when is_binary(folder_uuid) do
    file = if match?(%Storage.File{}, file), do: file, else: Storage.get_file(file_uuid)

    case file && Storage.attach_file_to_folder(file, folder_uuid) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("[Comments] could not place file #{file_uuid}: #{inspect(other)}")
        :ok
    end
  rescue
    # A folder deleted since the host answered: adopting a homeless file is a
    # plain `change/2` with no FK constraint declared, so the violation raises
    # instead of coming back as `{:error, changeset}`.
    error ->
      Logger.warning("[Comments] could not place file #{file_uuid}: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Comments] could not place file #{file_uuid}: #{PhoenixKitComments.describe_exit(reason)}"
      )

      :ok
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
