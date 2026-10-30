defmodule PhoenixKitComments.RemovalGuard do
  @moduledoc """
  Keeps comment attachments out of the media trash.

  A file that a comment shows is in use, but the media library only knows that
  from the foreign key on `phoenix_kit_comment_media.file_uuid` — which makes a
  permanent delete fail late instead of the move to the trash failing early.
  Core's `PhoenixKit.Modules.Storage.RemovalGuard` is the early check: this
  module answers it for comments.

      config :phoenix_kit, :file_removal_guard, PhoenixKitComments.RemovalGuard

  Core takes ONE guard module, so a host that already has its own calls
  `places/2` from it and appends the answer to its own:

      def places(file_uuids, ctx) do
        MyApp.Orders.places(file_uuids, ctx) ++ PhoenixKitComments.RemovalGuard.places(file_uuids, ctx)
      end

  `release/2` is deliberately not implemented: freeing a file would strip the
  picture from someone's comment, which is not a decision for a media-page
  button. Delete the comment, or detach the attachment in the comment.

  The label is `nil` — "not available to you" in the browser — for a person
  without access to the comments module, so the dialog never tells them where
  a file they cannot see is used.
  """
  @behaviour PhoenixKit.Modules.Storage.RemovalGuard

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitComments.{Comment, CommentMedia}

  use Gettext, backend: PhoenixKitComments.Gettext

  @impl true
  def places([], _ctx), do: []

  def places(file_uuids, ctx) when is_list(file_uuids) do
    visible? = visible?(ctx)

    # One place per file: a file shown by several comments is listed once, at
    # the oldest, so the dialog stays as long as the selection.
    from(m in CommentMedia,
      join: c in Comment,
      on: c.uuid == m.comment_uuid,
      where: m.file_uuid in ^file_uuids,
      order_by: [asc: c.inserted_at, asc: c.uuid],
      select: {m.file_uuid, c.resource_type}
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {file_uuid, resource_type} -> place(file_uuid, resource_type, visible?) end)
  end

  defp place(file_uuid, _resource_type, false),
    do: %{file_uuid: file_uuid, label: nil, detail: nil, href: nil}

  defp place(file_uuid, resource_type, true) do
    %{
      file_uuid: file_uuid,
      label: gettext("Attached to a comment"),
      detail: gettext("On: %{type}", type: resource_type),
      href: nil
    }
  end

  defp visible?(%{scope: %Scope{} = scope}),
    do: Scope.has_module_access?(scope, PhoenixKitComments.module_key())

  defp visible?(_ctx), do: false
end
