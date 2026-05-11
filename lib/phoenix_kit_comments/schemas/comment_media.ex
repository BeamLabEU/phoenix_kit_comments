defmodule PhoenixKitComments.CommentMedia do
  @moduledoc """
  Junction schema linking a comment to an uploaded file.

  Mirrors `PhoenixKitPosts.PostMedia` — each row attaches one
  `PhoenixKit.Modules.Storage.File` to one `PhoenixKitComments.Comment`
  with a stable `position` and an optional `caption`.

  ## Fields

  - `comment_uuid` - The comment this media belongs to
  - `file_uuid` - The `Storage.File` row (image / video / audio / document / other)
  - `position` - 1-based display order within the comment's media list
  - `caption` - Optional caption / alt text

  ## Constraints

  - Unique `(comment_uuid, position)` so reordering can't collide
  - `ON DELETE CASCADE` on `comment_uuid`: deleting a comment row also
    drops its media rows
  - `ON DELETE RESTRICT` on `file_uuid`: a file may be referenced by
    other comments or posts, so the junction row is the only thing
    detaching removes; the file is reaped by the storage GC pass when no
    junction rows reference it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          comment_uuid: UUIDv7.t(),
          file_uuid: UUIDv7.t(),
          position: integer(),
          caption: String.t() | nil,
          comment: PhoenixKitComments.Comment.t() | Ecto.Association.NotLoaded.t(),
          file: PhoenixKit.Modules.Storage.File.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comment_media" do
    field(:position, :integer)
    field(:caption, :string)

    belongs_to(:comment, PhoenixKitComments.Comment,
      foreign_key: :comment_uuid,
      references: :uuid
    )

    belongs_to(:file, PhoenixKit.Modules.Storage.File,
      foreign_key: :file_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a comment-media link.

  Position is required and must be positive. Uniqueness on
  `(comment_uuid, position)` is enforced at the DB level.
  """
  def changeset(media, attrs) do
    media
    |> cast(attrs, [:comment_uuid, :file_uuid, :position, :caption])
    |> validate_required([:comment_uuid, :file_uuid, :position])
    |> validate_number(:position, greater_than: 0)
    |> validate_length(:caption, max: 500)
    |> foreign_key_constraint(:comment_uuid)
    |> foreign_key_constraint(:file_uuid)
    |> unique_constraint([:comment_uuid, :position],
      name: :phoenix_kit_comment_media_comment_position_index,
      message: "position already taken for this comment"
    )
  end
end
