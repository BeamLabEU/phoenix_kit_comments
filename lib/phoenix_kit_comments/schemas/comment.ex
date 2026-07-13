defmodule PhoenixKitComments.Comment do
  @moduledoc """
  Schema for polymorphic comments with unlimited threading depth.

  Supports nested comment threads (Reddit-style) with self-referencing parent/child
  relationships. Can be attached to any resource type via `resource_type` + `resource_uuid`.

  ## Comment Status

  - `published` - Comment is visible
  - `hidden` - Comment is hidden by moderator
  - `deleted` - Comment deleted (soft delete)
  - `pending` - Awaiting moderation approval

  ## Fields

  - `resource_type` - Type of resource (e.g., "post", "entity", "ticket")
  - `resource_uuid` - UUID of the resource
  - `user_uuid` - Reference to the commenter
  - `parent_uuid` - Reference to parent comment (nil for top-level)
  - `content` - Comment text
  - `status` - published/hidden/deleted/pending
  - `depth` - Nesting level (0=top, 1=reply, 2=reply-to-reply, etc.)
  - `like_count` - Denormalized like counter
  - `dislike_count` - Denormalized dislike counter
  - `metadata` - Arbitrary JSONB data (giphy reactions, custom flags, rich embeds, etc.)

  ## Media

  The `has_many :media` association links to `PhoenixKitComments.CommentMedia`
  rows ordered by `position`. Content-or-media validation (`content` is
  optional iff Giphy or media is present) checks the loaded association
  on updates; the orchestrator passes `has_media: true` on insert when
  it's about to attach files in the same transaction.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          resource_type: String.t(),
          resource_uuid: Ecto.UUID.t(),
          user_uuid: UUIDv7.t() | nil,
          parent_uuid: UUIDv7.t() | nil,
          content: String.t(),
          status: String.t(),
          depth: integer(),
          like_count: integer(),
          dislike_count: integer(),
          metadata: map(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          parent: t() | Ecto.Association.NotLoaded.t() | nil,
          children: [t()] | Ecto.Association.NotLoaded.t(),
          media: [PhoenixKitComments.CommentMedia.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comments" do
    field(:resource_type, :string)
    field(:resource_uuid, Ecto.UUID)
    field(:content, :string)
    field(:status, :string, default: "published")
    field(:depth, :integer, default: 0)
    field(:like_count, :integer, default: 0)
    field(:dislike_count, :integer, default: 0)
    field(:metadata, :map, default: %{})

    belongs_to(:user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:children, __MODULE__, foreign_key: :parent_uuid)

    has_many(:media, PhoenixKitComments.CommentMedia,
      foreign_key: :comment_uuid,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a comment.

  ## Required Fields

  - `resource_type` - Type of resource being commented on
  - `resource_uuid` - UUID of the resource
  - `user_uuid` - Reference to commenter
  - Either `content`, a Giphy attachment in `metadata["giphy"]`, or media

  ## Options

  - `:has_media` — boolean. When set, overrides the inferred media
    presence (used by `PhoenixKitComments.create_comment/4` because the
    new comment has no `uuid` yet and the `media` association is not
    loaded). Not part of `cast` — callers cannot drive it via attrs.
  """
  def changeset(comment, attrs, opts \\ []) do
    comment
    |> cast(attrs, [
      :resource_type,
      :resource_uuid,
      :user_uuid,
      :parent_uuid,
      :content,
      :status,
      :depth,
      :metadata
    ])
    |> validate_required([:resource_type, :resource_uuid, :user_uuid])
    |> validate_inclusion(:status, ["published", "hidden", "deleted", "pending"])
    |> validate_length(:content, max: 10_000)
    |> validate_length(:resource_type, max: 50)
    |> ensure_content_not_nil()
    |> validate_content_or_media(opts)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:parent_uuid)
  end

  defp ensure_content_not_nil(changeset) do
    if get_field(changeset, :content) == nil do
      put_change(changeset, :content, "")
    else
      changeset
    end
  end

  # Status-only / counter-only updates don't change content or metadata,
  # so the existing record was already validated at insert (or last
  # content edit). Skipping avoids forcing every status-only update path
  # — including `bulk_update_status/2` — to preload `:media` just to
  # re-prove the original invariant.
  defp validate_content_or_media(changeset, opts) do
    inserting? = is_nil(get_field(changeset, :uuid))
    content_changing? = Map.has_key?(changeset.changes, :content)
    metadata_changing? = Map.has_key?(changeset.changes, :metadata)

    if inserting? or content_changing? or metadata_changing? do
      do_validate_content_or_media(changeset, opts)
    else
      changeset
    end
  end

  defp do_validate_content_or_media(changeset, opts) do
    content = changeset |> get_field(:content) |> to_string() |> String.trim()
    metadata = get_field(changeset, :metadata) || %{}

    has_gif? =
      is_map(metadata) and
        match?(%{"url" => u} when is_binary(u) and u != "", metadata["giphy"])

    has_media? = resolve_has_media(changeset, opts)

    cond do
      content != "" -> changeset
      has_gif? -> changeset
      has_media? -> changeset
      true -> add_error(changeset, :content, "can't be blank without a GIF or attachment")
    end
  end

  defp resolve_has_media(changeset, opts) do
    case Keyword.fetch(opts, :has_media) do
      {:ok, value} when is_boolean(value) -> value
      _ -> infer_has_media(changeset)
    end
  end

  defp infer_has_media(changeset) do
    case get_field(changeset, :media) do
      media when is_list(media) and media != [] -> true
      _ -> false
    end
  end

  @doc "Check if comment is a reply (has parent)."
  def reply?(%__MODULE__{parent_uuid: nil}), do: false
  def reply?(%__MODULE__{}), do: true

  @doc "Check if comment is top-level (no parent)."
  def top_level?(%__MODULE__{parent_uuid: nil}), do: true
  def top_level?(%__MODULE__{}), do: false

  @doc "Check if comment is published."
  def published?(%__MODULE__{status: "published"}), do: true
  def published?(_), do: false

  @doc "Check if comment is deleted."
  def deleted?(%__MODULE__{status: "deleted"}), do: true
  def deleted?(_), do: false
end
