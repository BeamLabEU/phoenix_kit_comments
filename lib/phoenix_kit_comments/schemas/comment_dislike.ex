defmodule PhoenixKitComments.CommentDislike do
  @moduledoc """
  Schema for comment dislikes in the standalone Comments module.

  Tracks which users have disliked which comments. One dislike per user per
  comment is kept by `PhoenixKitComments.dislike_comment/2`, which locks the
  comment row and checks for an existing dislike in one transaction: the table
  has NO unique index on `(comment_uuid, user_uuid)`, so a row written around
  that function can duplicate one.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          comment_uuid: UUIDv7.t(),
          user_uuid: UUIDv7.t() | nil,
          comment: PhoenixKitComments.Comment.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_comments_dislikes" do
    belongs_to(:comment, PhoenixKitComments.Comment,
      foreign_key: :comment_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a comment dislike.

  The `unique_constraint` names the index a future version of this module's
  chain will add (see AGENTS.md, TODOs); until then it never fires.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(dislike, attrs) do
    dislike
    |> cast(attrs, [:comment_uuid, :user_uuid])
    |> validate_required([:comment_uuid, :user_uuid])
    # The table's real constraint names (`Migrations`); under Ecto's defaults
    # a missing comment or user raised `Ecto.ConstraintError`.
    |> foreign_key_constraint(:comment_uuid, name: :fk_comments_dislikes_comment)
    |> foreign_key_constraint(:user_uuid, name: :fk_comments_dislikes_user_uuid)
    |> unique_constraint([:comment_uuid, :user_uuid],
      name: :uq_comments_dislikes_comment_user,
      message: "you have already disliked this comment"
    )
  end
end
