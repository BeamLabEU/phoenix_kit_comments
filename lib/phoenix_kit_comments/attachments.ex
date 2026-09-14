defmodule PhoenixKitComments.Attachments do
  @moduledoc """
  Where comment attachments are stored. By default `Storage.store_file/2`
  leaves them at the media root; a host can place them next to the
  commented record:

      config :phoenix_kit_comments, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:comment_attachment, actor_uuid, %{resource_type: type, resource_uuid: uuid})`
  (or `parent_for(:comment_attachment, actor_uuid)`), returning `{:ok, folder_uuid}` or `nil`.
  """
  require Logger
  alias PhoenixKit.Modules.Storage

  @kind :comment_attachment

  @doc """
  Asks the host hook where attachments for `resource_type`/`resource_uuid`
  should live. `nil` (no config, no clause, a `nil` answer, or the hook
  raising) means "leave it at the media root" — today's behaviour.
  """
  @spec parent_folder_uuid(String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def parent_folder_uuid(resource_type, resource_uuid, actor_uuid) do
    subject = %{resource_type: resource_type, resource_uuid: resource_uuid}

    case Application.get_env(:phoenix_kit_comments, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        case call_hook(mod, fun, actor_uuid, subject) do
          {:ok, uuid} when is_binary(uuid) -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("[Comments] parent folder hook failed: #{inspect(error)}")
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

  @doc "Attach a just-stored file to the host-chosen folder; no-op without a host answer."
  @spec place_stored_file(Storage.File.t() | map(), String.t(), String.t(), String.t() | nil) ::
          :ok
  def place_stored_file(%{uuid: file_uuid} = file, resource_type, resource_uuid, actor_uuid) do
    case parent_folder_uuid(resource_type, resource_uuid, actor_uuid) do
      nil ->
        :ok

      folder_uuid ->
        file = if match?(%Storage.File{}, file), do: file, else: Storage.get_file(file_uuid)

        case file && Storage.attach_file_to_folder(file, folder_uuid) do
          {:ok, _} ->
            :ok

          other ->
            Logger.warning("[Comments] could not place file #{file_uuid}: #{inspect(other)}")
            :ok
        end
    end
  end
end
