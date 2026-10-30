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

  The label is `nil` — "not available to you" in the browser — unless the
  viewer may moderate comments on the resource. The base comments key alone
  does not reveal uses outside the handler's moderation scope.

  Older core versions can compile this module and hosts can call `places/2`
  directly; the media-browser integration requires a core with removal guards.
  """
  # Removal guards arrived after the oldest core this package supports.
  if Code.ensure_loaded?(PhoenixKit.Modules.Storage.RemovalGuard) do
    @behaviour PhoenixKit.Modules.Storage.RemovalGuard
  end

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitComments.{Comment, CommentMedia}

  use Gettext, backend: PhoenixKitComments.Gettext

  if Code.ensure_loaded?(PhoenixKit.Modules.Storage.RemovalGuard) do
    @impl true
  end

  def places([], _ctx), do: []

  def places(file_uuids, ctx) when is_list(file_uuids) do
    rule = moderation_rule(ctx)

    # One place per file, preferring its oldest visible use. Hidden uses
    # still block removal, but never reveal their resource type.
    from(m in CommentMedia,
      join: c in Comment,
      on: c.uuid == m.comment_uuid,
      where: m.file_uuid in ^file_uuids,
      order_by: [asc: c.inserted_at, asc: c.uuid],
      select: {m.file_uuid, c.resource_type, c.resource_uuid}
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(&visible_place(&1, rule))
  end

  defp visible_place({file_uuid, uses}, rule) do
    case Enum.find(uses, fn {_, type, uuid} ->
           PhoenixKitComments.moderation_allows?(rule, type, uuid)
         end) do
      nil -> place(file_uuid, nil, false)
      {_, type, _} -> place(file_uuid, type, true)
    end
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

  defp moderation_rule(%{scope: scope}), do: PhoenixKitComments.moderation_scope(scope)

  defp moderation_rule(_ctx), do: nil
end
