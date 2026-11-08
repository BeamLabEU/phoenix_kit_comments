defmodule PhoenixKitComments.Comment do
  @moduledoc """
  Schema for polymorphic comments with threaded replies.

  Replies nest up to the `comments_max_depth` setting (default 10), which
  `PhoenixKitComments.create_comment/4` enforces; the schema itself puts no
  limit on `depth`.

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
          author_display_name: String.t() | nil,
          attribution_mode: String.t() | nil,
          attributed_project_uuid: Ecto.UUID.t() | nil,
          attributed_label: String.t() | nil,
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

    # ── Attribution, frozen at write ────────────────────────────────
    # Deliberately absent from `cast/3` below: these decide what the public
    # sees and whether someone is speaking for an organisation, so a client
    # that could set them could sign a comment as anyone. They are applied
    # by `put_attribution/2` from values the SERVER computed.
    field(:author_display_name, :string)
    field(:attribution_mode, :string)
    field(:attributed_project_uuid, Ecto.UUID)
    field(:attributed_label, :string)

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
  Freezes who this comment is from. Server-set only — never from `attrs`.

  `:personal` pins the display name the reader will see, so a later rename,
  a filled-in profile or a departure does not re-sign every comment the
  person ever wrote.

  `:project` additionally records that they were speaking for the project,
  and pins the project's name as it read at the time. **`user_uuid` is left
  exactly as it was**: the public sees the project, and internally the
  author is still on the row for moderation and audit. A shared voice with
  nobody accountable behind it is the failure mode of this feature.
  """
  @spec put_attribution(Ecto.Changeset.t(), map() | nil) :: Ecto.Changeset.t()
  def put_attribution(changeset, %{mode: "project"} = attribution) do
    # Cast, not put as given: `put_change/3` does not cast, so a host handing
    # over a project id that is not a uuid ("42") got `Ecto.ChangeError` from
    # the insert instead of an error tuple.
    case Ecto.UUID.cast(attribution[:project_uuid]) do
      {:ok, project_uuid} ->
        changeset
        |> put_change(:attribution_mode, "project")
        |> put_change(:author_display_name, attribution[:label])
        |> put_change(:attributed_project_uuid, project_uuid)
        |> put_change(:attributed_label, attribution[:label])
        |> validate_no_null_bytes()

      :error ->
        add_error(changeset, :attributed_project_uuid, "is invalid", validation: :cast)
    end
  end

  def put_attribution(changeset, %{mode: "personal"} = attribution) do
    changeset
    |> put_change(:attribution_mode, "personal")
    |> put_change(:author_display_name, attribution[:label])
    |> validate_no_null_bytes()
  end

  def put_attribution(changeset, _), do: changeset

  @doc """
  Changeset for creating a comment.

  ## Required Fields

  - `resource_type` - Type of resource being commented on
  - `resource_uuid` - UUID of the resource
  - `user_uuid` - Reference to commenter
  - Either `content`, a Giphy attachment in `metadata["giphy"]`, or media

  Updates go through `update_changeset/3`, which cannot move a comment.

  ## Options

  - `:has_media` — boolean. When set, overrides the inferred media
    presence (used by `PhoenixKitComments.create_comment/4` because the
    new comment has no `uuid` yet and the `media` association is not
    loaded). Not part of `cast` — callers cannot drive it via attrs.
  - `:allow_empty` — skip the content-or-media rule.

  ## Errors

  Besides Ecto's own, two errors carry a `:validation` a caller can match
  on to say something better than the message: `:content_or_media` (blank
  content with no GIF or media) and `:null_byte` (a U+0000 in a string —
  PostgreSQL cannot store one, and the insert raised instead of erroring).
  """
  @spec changeset(%__MODULE__{}, map(), keyword()) :: Ecto.Changeset.t()
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
    # Code points, as `varchar(50)` counts: graphemes let 50 "é" written as
    # e + U+0301 (100 code points) through to an insert that raised.
    |> validate_length(:resource_type, max: 50, count: :codepoints)
    |> validate_common(opts)
    # Core's constraint names (`Migrations`), not Ecto's `*_fkey` defaults:
    # under the default names a parent or author that does not exist raised
    # `Ecto.ConstraintError` out of `create_comment/4` instead of coming
    # back as `{:error, changeset}`.
    |> foreign_key_constraint(:user_uuid, name: :fk_comments_user_uuid)
    |> foreign_key_constraint(:parent_uuid, name: :fk_comments_parent)
  end

  @doc """
  Changeset for updating a comment: its `content`, `metadata` and `status`.

  Who wrote it, what it is on and where it sits in the thread are fixed at
  creation. The create changeset casts them, and `update_comment/3` used it,
  so a caller forwarding params could re-sign a comment as someone else,
  move it to another record, or make it its own parent — after which it
  vanished from the thread.

  Takes the options and returns the errors of `changeset/3`.
  """
  @spec update_changeset(%__MODULE__{}, map(), keyword()) :: Ecto.Changeset.t()
  def update_changeset(comment, attrs, opts \\ []) do
    comment
    |> cast(attrs, [:content, :status, :metadata])
    |> validate_common(opts)
  end

  defp validate_common(changeset, opts) do
    changeset
    |> validate_inclusion(:status, ["published", "hidden", "deleted", "pending"])
    # Matches the ceiling `comments_max_length` can be clamped to
    # (`Web.Settings` allows up to 100_000). It used to be 10_000 while the
    # setting went to 100_000, so an admin raising the setting produced
    # comments that passed the context's own length check and were then
    # refused by the changeset with "should be at most 10000 character(s)" —
    # a limit the admin had explicitly changed.
    |> validate_length(:content, max: 100_000)
    |> ensure_content_not_nil()
    |> validate_no_null_bytes()
    |> validate_content_or_media(opts)
  end

  # PostgreSQL stores no U+0000, in `text` (22021) or in `jsonb` (22P05),
  # and the error is RAISED, not returned: one crafted submit took the host
  # LiveView down, with the draft in the crash report. Every string change
  # is checked, nested metadata included.
  defp validate_no_null_bytes(changeset) do
    Enum.reduce(changeset.changes, changeset, fn {field, value}, acc ->
      if null_byte?(value),
        do:
          add_error(acc, field, "contains a character that cannot be saved",
            validation: :null_byte
          ),
        else: acc
    end)
  end

  defp null_byte?(value) when is_binary(value), do: String.contains?(value, <<0>>)

  defp null_byte?(value) when is_map(value) and not is_struct(value),
    do: Enum.any?(value, fn {k, v} -> null_byte?(k) or null_byte?(v) end)

  defp null_byte?(value) when is_list(value), do: Enum.any?(value, &null_byte?/1)
  defp null_byte?(_value), do: false

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
    if opts[:allow_empty] do
      changeset
    else
      require_content_or_media(changeset, opts)
    end
  end

  defp require_content_or_media(changeset, opts) do
    content = changeset |> get_field(:content) |> to_string() |> String.trim()
    metadata = get_field(changeset, :metadata) || %{}

    has_gif? =
      is_map(metadata) and
        match?(%{"url" => u} when is_binary(u) and u != "", metadata["giphy"])

    has_media? = resolve_has_media(changeset, opts)

    cond do
      content != "" ->
        changeset

      has_gif? ->
        changeset

      has_media? ->
        changeset

      true ->
        add_error(changeset, :content, "can't be blank without a GIF or attachment",
          validation: :content_or_media
        )
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
