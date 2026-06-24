defmodule PhoenixKitComments do
  @moduledoc """
  Standalone, resource-agnostic comments module.

  Provides polymorphic commenting for any resource type (posts, entities, tickets, etc.)
  with unlimited threading, likes/dislikes, and moderation support.

  ## Architecture

  Comments are linked to resources via `resource_type` (string) + `resource_uuid` (UUID).
  No foreign key constraints on the resource side — any module can use comments.

  ## Resource Handler Callbacks

  Modules that consume comments can register handlers to receive notifications
  when comments are created or deleted. Configure in your app:

      config :phoenix_kit, :comment_resource_handlers, %{
        "post" => PhoenixKitPosts
      }

  Handler modules may implement any of these optional callbacks (each guarded
  by `function_exported?/3`, so implement only what you need):

  * `on_comment_created(resource_type, resource_uuid, comment)` — new comment
    (check `comment.parent_uuid` to distinguish a reply).
  * `on_comment_deleted(resource_type, resource_uuid, comment)` — comment removed.
  * `on_comment_liked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_unliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_disliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_undisliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`

  The reaction callbacks fire only when the reaction state actually changed
  (`{:ok, :liked}` / `{:ok, :unliked}` …), never on `:already_liked` no-ops.
  Self-action skipping (e.g. don't notify someone who liked their own comment)
  is left to the host. The `liker_uuid` is in the payload because the comment
  row carries the author, not the reacting user.

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if Comments module is enabled
  - `enable_system/0` - Enable the Comments module
  - `disable_system/0` - Disable the Comments module
  - `get_config/0` - Get module configuration with statistics

  ### Comment CRUD
  - `create_comment/4` - Create a comment on a resource
  - `update_comment/2` - Update a comment
  - `delete_comment/1` - Delete a comment
  - `get_comment/2`, `get_comment!/2` - Get by ID
  - `list_comments/3` - Flat list for a resource
  - `get_comment_tree/2` - Nested tree for a resource
  - `count_comments/3` - Count comments for a resource

  ### Moderation
  - `approve_comment/1` - Set status to published
  - `hide_comment/1` - Set status to hidden
  - `bulk_update_status/2` - Bulk status changes
  - `list_all_comments/1` - Cross-resource listing with filters
  - `comment_stats/0` - Aggregate statistics

  ### Like/Dislike
  - `like_comment/2`, `unlike_comment/2`, `comment_liked_by?/2`
  - `dislike_comment/2`, `undislike_comment/2`, `comment_disliked_by?/2`
  """

  use PhoenixKit.Module

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.CommentDislike
  alias PhoenixKitComments.CommentLike
  alias PhoenixKitComments.CommentMedia

  # ============================================================================
  # Module Status
  # ============================================================================

  @impl PhoenixKit.Module
  @doc "Checks if the Comments module is enabled."
  def enabled? do
    Settings.get_boolean_setting("comments_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  @doc "Enables the Comments module."
  def enable_system do
    Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
  end

  @impl PhoenixKit.Module
  @doc "Disables the Comments module."
  def disable_system do
    Settings.update_boolean_setting_with_module("comments_enabled", false, "comments")
  end

  @impl PhoenixKit.Module
  @doc "Gets the Comments module configuration with statistics."
  def get_config do
    %{
      enabled: enabled?(),
      total_comments: count_all_comments(),
      published_comments: count_all_comments(status: "published"),
      pending_comments: count_all_comments(status: "pending"),
      moderation_enabled: Settings.get_boolean_setting("comments_moderation", false),
      max_depth: get_max_depth(),
      max_length: get_max_length()
    }
  end

  @doc "Returns the configured maximum comment depth."
  def get_max_depth do
    case Integer.parse(Settings.get_setting("comments_max_depth", "10")) do
      {n, _} -> n
      :error -> 10
    end
  end

  @doc "Returns the configured maximum comment length."
  def get_max_length do
    case Integer.parse(Settings.get_setting("comments_max_length", "10000")) do
      {n, _} -> n
      :error -> 10_000
    end
  end

  # ============================================================================
  # Composer / editor configuration
  # ============================================================================

  @doc """
  Returns `true` when the rich-text (Leaf) editor should be used in the
  comment composer.

  The Leaf editor requires the host application to register Leaf's JS hook in
  its `LiveSocket`. When the hook is missing the editor hangs on its loading
  text with no server error — so hosts that haven't wired the JS (or simply
  don't want rich text) can fall back to the always-working plain `<textarea>`
  by setting `comments_rich_text` to `false`, or by passing
  `rich_text={false}` to `CommentsComponent`.

  Defaults to `true`. Leaf is provided transitively by PhoenixKit; the module
  still falls back to a plain `<textarea>` whenever Leaf is unavailable.
  """
  @spec rich_text_enabled?() :: boolean()
  def rich_text_enabled? do
    Settings.get_boolean_setting("comments_rich_text", true)
  rescue
    _ -> true
  end

  # ============================================================================
  # Attachments configuration
  # ============================================================================

  @doc "Returns `true` when comment attachments are enabled in settings."
  @spec attachments_enabled?() :: boolean()
  def attachments_enabled? do
    Settings.get_boolean_setting("comments_attachments_enabled", false)
  rescue
    _ -> false
  end

  @doc "Returns the per-comment attachment count cap (default 4)."
  @spec get_max_attachments() :: pos_integer()
  def get_max_attachments do
    case Integer.parse(Settings.get_setting("comments_max_attachments", "4")) do
      {n, _} when n > 0 -> n
      _ -> 4
    end
  rescue
    _ -> 4
  end

  @doc """
  Returns the per-attachment size cap in MB.

  Clamped against the global `storage_max_upload_size_mb` so an admin
  can't accidentally let comment uploads exceed the platform cap.
  """
  @spec get_max_attachment_size_mb() :: pos_integer()
  def get_max_attachment_size_mb do
    comment_cap = parse_size_setting("comments_attachment_max_size_mb", 20)
    global_cap = parse_size_setting("storage_max_upload_size_mb", 500)
    min(comment_cap, global_cap)
  end

  defp parse_size_setting(key, default) do
    case Integer.parse(Settings.get_setting(key, Integer.to_string(default))) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  rescue
    _ -> default
  end

  # ============================================================================
  # Giphy Integration
  # ============================================================================

  @type gif_map :: %{
          required(String.t()) => String.t() | integer() | nil
        }

  @doc """
  Returns `true` when the Giphy picker should be shown in the comment form.

  Requires both the `comments_giphy_enabled` toggle and a non-empty API key.
  """
  @spec giphy_enabled?() :: boolean()
  def giphy_enabled? do
    Settings.get_boolean_setting("comments_giphy_enabled", false) and
      get_giphy_api_key() != ""
  end

  @doc "Returns the configured Giphy API key (empty string when unset)."
  @spec get_giphy_api_key() :: String.t()
  def get_giphy_api_key, do: Settings.get_setting("comments_giphy_api_key", "")

  @doc "Returns the configured Giphy content rating (g/pg/pg-13/r)."
  @spec get_giphy_rating() :: String.t()
  def get_giphy_rating, do: Settings.get_setting("comments_giphy_rating", "g")

  @doc """
  Searches Giphy for GIFs matching the query, using the configured API key and rating.

  Returns `{:ok, [gif_map]}` on success or `{:error, reason}` on failure. Each `gif_map`
  has string keys: `"id"`, `"url"` (original image), `"preview_url"` (thumbnail),
  `"width"`, `"height"`.
  """
  @spec search_giphy(String.t(), keyword()) ::
          {:ok, [gif_map()]} | {:error, atom()}
  def search_giphy(query, opts \\ []) when is_binary(query) do
    case String.trim(query) do
      "" ->
        {:ok, []}

      trimmed ->
        case get_giphy_api_key() do
          "" ->
            {:error, :missing_api_key}

          api_key ->
            rating = get_giphy_rating()
            limit = Keyword.get(opts, :limit, 24)

            try do
              case GiphyApi.search(trimmed,
                     api_key: api_key,
                     rating: rating,
                     limit: limit
                   ) do
                {:ok, results} ->
                  {:ok, results |> Enum.map(&normalize_giphy_gif/1) |> Enum.reject(&is_nil/1)}

                {:error, _} = err ->
                  err
              end
            rescue
              e ->
                Logger.warning("Giphy search failed: #{inspect(e)}")
                {:error, :giphy_error}
            end
        end
    end
  end

  defp normalize_giphy_gif(%GiphyApi.Gif{} = gif) do
    if giphy_host?(gif.original_url) and giphy_host?(gif.preview_url) do
      %{
        "id" => gif.id,
        "url" => gif.original_url,
        "preview_url" => gif.preview_url,
        "width" => gif.original_width,
        "height" => gif.original_height
      }
    end
  end

  defp giphy_host?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        String.ends_with?(host, ".giphy.com") or host == "giphy.com"

      _ ->
        false
    end
  end

  defp giphy_host?(_), do: false

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "comments"

  @impl PhoenixKit.Module
  def module_name, do: "Comments"

  @impl PhoenixKit.Module
  def version, do: Application.spec(:phoenix_kit_comments, :vsn) |> to_string()

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "comments",
      label: "Comments",
      icon: "hero-chat-bubble-left-right",
      description: "Comment moderation, threading, and reactions across all content types"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_comments,
        label: "Comments",
        icon: "hero-chat-bubble-left-right",
        path: "comments",
        priority: 590,
        level: :admin,
        permission: "comments",
        match: :prefix,
        group: :admin_modules,
        live_view: {PhoenixKitComments.Web.Index, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_comments,
        label: "Comments",
        icon: "hero-chat-bubble-left-right",
        path: "comments",
        priority: 924,
        level: :admin,
        parent: :admin_settings,
        permission: "comments",
        live_view: {PhoenixKitComments.Web.Settings, :settings}
      )
    ]
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_comments]

  # ============================================================================
  # Comment CRUD
  # ============================================================================

  @doc """
  Creates a comment on a resource.

  Automatically calculates depth from parent. Invokes resource handler callback
  if configured.

  ## Parameters

  - `resource_type` - Type of resource (e.g., "post")
  - `resource_uuid` - UUID of the resource
  - `user_uuid` - UUID of commenter
  - `attrs` - Comment attributes (content, parent_uuid, metadata, etc.).
    May include `:attachment_file_uuids` — a list of
    `PhoenixKit.Modules.Storage.File` UUIDs to attach to the new comment
    in display order. Comment insert + attachments run in one
    transaction; any attach failure rolls back the comment too.
  """
  def create_comment(resource_type, resource_uuid, user_uuid, attrs) when is_binary(user_uuid) do
    if UUIDUtils.valid?(user_uuid) do
      do_create_comment(resource_type, resource_uuid, user_uuid, attrs)
    else
      {:error, :invalid_user_uuid}
    end
  end

  @doc """
  Validates a prospective comment before any uploads are consumed.

  Use this in form handlers ahead of `Phoenix.LiveView.consume_uploaded_entries/3`
  so that depth / length / attachment-cap failures don't leak files into
  the storage backend. Accepts the same attrs as `create_comment/4`
  except `:attachment_file_uuids` — pass `entry_count` instead, which is
  how many uploads are currently staged on the LiveView.

  Returns `:ok` or `{:error, reason}` with the same reasons
  `create_comment/4` would surface (`:invalid_user_uuid`,
  `:max_depth_exceeded`, `:content_too_long`, `:attachments_disabled`,
  `:too_many_attachments`, `:empty_comment`).
  """
  @spec precheck_create(String.t(), term(), String.t(), map(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def precheck_create(resource_type, resource_uuid, user_uuid, attrs, entry_count \\ 0)
      when is_binary(user_uuid) and is_integer(entry_count) and entry_count >= 0 do
    if UUIDUtils.valid?(user_uuid) do
      prepared = prepare_create_attrs(resource_type, resource_uuid, user_uuid, attrs)
      run_cheap_validators(prepared, entry_count)
    else
      {:error, :invalid_user_uuid}
    end
  end

  defp do_create_comment(resource_type, resource_uuid, user_uuid, attrs) do
    {file_uuids, attrs} = Map.pop(attrs, :attachment_file_uuids, [])
    file_uuids = List.wrap(file_uuids)
    attrs = prepare_create_attrs(resource_type, resource_uuid, user_uuid, attrs)

    with :ok <- run_cheap_validators(attrs, length(file_uuids)),
         :ok <- validate_file_uuid_format(file_uuids),
         {:ok, comment} <- insert_comment_with_attachments(attrs, file_uuids) do
      notify_resource_handler(:on_comment_created, resource_type, resource_uuid, comment)
      broadcast_change(resource_type, resource_uuid, :created)
      {:ok, comment}
    end
  end

  defp prepare_create_attrs(resource_type, resource_uuid, user_uuid, attrs) do
    attrs
    |> Map.put(:resource_type, resource_type)
    |> Map.put(:resource_uuid, resource_uuid)
    |> Map.put(:user_uuid, user_uuid)
    |> maybe_calculate_depth()
    |> maybe_set_initial_status()
  end

  defp run_cheap_validators(attrs, file_count) do
    with :ok <- validate_depth(attrs),
         :ok <- validate_content_length(attrs),
         :ok <- validate_attachment_count(file_count) do
      validate_has_body(attrs, file_count)
    end
  end

  defp insert_comment_with_attachments(attrs, []) do
    %Comment{} |> Comment.changeset(attrs, has_media: false) |> repo().insert()
  end

  defp insert_comment_with_attachments(attrs, file_uuids) do
    repo().transaction(fn ->
      with {:ok, comment} <-
             %Comment{} |> Comment.changeset(attrs, has_media: true) |> repo().insert(),
           :ok <- attach_files(comment.uuid, file_uuids) do
        repo().preload(comment, media: :file)
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp attach_files(comment_uuid, file_uuids) do
    file_uuids
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {file_uuid, position}, _acc ->
      case attach_media(comment_uuid, file_uuid, position: position) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # Cap + feature-flag checks that don't need the file UUIDs themselves.
  # Run by `precheck_create/5` before the LiveView consumes uploads, and
  # again inside `create_comment/4` so non-LiveView callers stay covered.
  defp validate_attachment_count(0), do: :ok

  defp validate_attachment_count(count) when is_integer(count) and count > 0 do
    cond do
      not attachments_enabled?() -> {:error, :attachments_disabled}
      count > get_max_attachments() -> {:error, :too_many_attachments}
      true -> :ok
    end
  end

  defp validate_file_uuid_format([]), do: :ok

  defp validate_file_uuid_format(file_uuids) when is_list(file_uuids) do
    if Enum.any?(file_uuids, &(not UUIDUtils.valid?(to_string(&1)))) do
      {:error, :invalid_file_uuid}
    else
      :ok
    end
  end

  defp validate_has_body(attrs, file_count) do
    cond do
      has_content?(attrs) -> :ok
      has_giphy?(attrs) -> :ok
      file_count > 0 -> :ok
      true -> {:error, :empty_comment}
    end
  end

  defp has_content?(attrs) do
    content = attrs[:content] || attrs["content"] || ""
    String.trim(to_string(content)) != ""
  end

  defp has_giphy?(attrs) do
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    is_map(metadata) and
      match?(%{"url" => u} when is_binary(u) and u != "", metadata["giphy"])
  end

  @doc """
  Updates a comment.

  ## Parameters

  - `comment` - Comment to update
  - `attrs` - Attributes to update (content, status)
  """
  def update_comment(%Comment{} = comment, attrs) do
    # Preload :media so the changeset can infer "has media" when content
    # is being changed. Status-only updates skip the content-or-media
    # check entirely (see `Comment.changeset/3`), so this is a no-op on
    # moderation paths if `:media` is already loaded; but we ensure it
    # for content edits because the caller may pass a bare struct from
    # `get_comment/1`.
    comment
    |> ensure_media_loaded()
    |> Comment.changeset(attrs)
    |> repo().update()
  end

  defp ensure_media_loaded(%Comment{media: %Ecto.Association.NotLoaded{}} = comment) do
    repo().preload(comment, :media)
  end

  defp ensure_media_loaded(%Comment{} = comment), do: comment

  @doc """
  Soft-deletes a comment by setting its status to "deleted".

  Invokes resource handler callback if configured.
  """
  def delete_comment(%Comment{} = comment) do
    case update_comment(comment, %{status: "deleted"}) do
      {:ok, deleted} ->
        notify_resource_handler(
          :on_comment_deleted,
          comment.resource_type,
          comment.resource_uuid,
          deleted
        )

        broadcast_change(comment.resource_type, comment.resource_uuid, :deleted)

        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Gets a single comment by ID with optional preloads.

  Returns `nil` if not found.
  """
  def get_comment(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case repo().get(Comment, id) do
      nil -> nil
      comment -> repo().preload(comment, preloads)
    end
  end

  @doc """
  Gets a single comment by ID with optional preloads.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_comment!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    Comment
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Gets nested comment tree for a resource.

  Returns all published comments organized in a tree structure. Deleted
  comments with published descendants are preserved as `[removed]`
  placeholders so reply chains stay attached; deleted leaves are pruned.
  """
  def get_comment_tree(resource_type, resource_uuid) do
    comments =
      from(c in Comment,
        where:
          c.resource_type == ^resource_type and
            c.resource_uuid == ^resource_uuid and
            c.status in ["published", "deleted"],
        order_by: [asc: c.inserted_at],
        preload: [:user, media: :file]
      )
      |> repo().all()

    build_comment_tree(comments)
  end

  @doc """
  Lists comments for a resource (flat list).

  Soft-deleted comments are excluded by default. Pass `include_deleted: true`
  (or an explicit `status:`) for admin callers that need them.

  ## Options

  - `:preload` - Associations to preload
  - `:status` - Filter by status
  - `:include_deleted` - Include `status == "deleted"` rows (default: false)
  """
  def list_comments(resource_type, resource_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_uuid,
        order_by: [asc: c.inserted_at]
      )

    query = apply_status_filter(query, status, include_deleted)

    query
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Counts comments for a resource, or a batch of resources.

  When `resource_uuid` is a single UUID, returns the integer count for that
  resource. When a **list** of UUIDs is given, returns a `uuid => count` map
  in a single grouped query — including a `0` entry for every requested UUID
  with no comments, so callers can render every row uniformly without an
  N+1 (see `count_comments/3` with a list below).

  Mirrors `list_comments/3`: deleted rows are excluded unless `:status` is
  set explicitly or `include_deleted: true` is passed.

  ## Examples

      iex> count_comments("order", order_uuid)
      3

      iex> count_comments("order", [uuid_a, uuid_b, uuid_c])
      %{uuid_a => 3, uuid_b => 0, uuid_c => 7}
  """
  @spec count_comments(String.t(), Ecto.UUID.t() | [Ecto.UUID.t()], keyword()) ::
          non_neg_integer() | %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def count_comments(resource_type, resource_uuid_or_uuids, opts \\ [])

  def count_comments(resource_type, resource_uuids, opts) when is_list(resource_uuids) do
    status = Keyword.get(opts, :status)
    include_deleted = Keyword.get(opts, :include_deleted, false)
    uuids = Enum.uniq(resource_uuids)

    counts =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid in ^uuids,
        group_by: c.resource_uuid,
        select: {c.resource_uuid, count(c.uuid)}
      )
      |> apply_status_filter(status, include_deleted)
      |> repo().all()
      |> Map.new()

    Map.new(uuids, fn uuid -> {uuid, Map.get(counts, uuid, 0)} end)
  rescue
    _ -> Map.new(Enum.uniq(resource_uuids), &{&1, 0})
  end

  def count_comments(resource_type, resource_uuid, opts) do
    status = Keyword.get(opts, :status)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_uuid
      )

    query = apply_status_filter(query, status, include_deleted)

    repo().aggregate(query, :count)
  rescue
    _ -> 0
  end

  defp apply_status_filter(query, nil, false), do: where(query, [c], c.status != "deleted")
  defp apply_status_filter(query, nil, true), do: query
  defp apply_status_filter(query, status, _), do: where(query, [c], c.status == ^status)

  # ============================================================================
  # Moderation
  # ============================================================================

  @doc "Sets a comment's status to published."
  def approve_comment(%Comment{} = comment) do
    update_comment(comment, %{status: "published"})
  end

  @doc "Sets a comment's status to hidden."
  def hide_comment(%Comment{} = comment) do
    update_comment(comment, %{status: "hidden"})
  end

  @doc """
  Bulk-updates status for multiple comment UUIDs.

  Routes through `update_comment/2` (and `delete_comment/1` for the
  `"deleted"` case) so resource-handler callbacks fire per row. Returns
  `{ok_count, error_count}`.
  """
  def bulk_update_status(comment_uuids, status)
      when is_list(comment_uuids) and status in ["published", "hidden", "deleted", "pending"] do
    comments =
      from(c in Comment, where: c.uuid in ^comment_uuids)
      |> repo().all()

    Enum.reduce(comments, {0, 0}, fn comment, {ok, err} ->
      result =
        case status do
          "deleted" -> delete_comment(comment)
          _ -> update_comment(comment, %{status: status})
        end

      case result do
        {:ok, _} -> {ok + 1, err}
        _ -> {ok, err + 1}
      end
    end)
  end

  @doc """
  Lists all comments across all resource types with filters.

  ## Options

  - `:resource_type` - Filter by resource type
  - `:status` - Filter by status
  - `:user_uuid` - Filter by user
  - `:search` - Search in content
  - `:page` - Page number (default: 1)
  - `:per_page` - Items per page (default: 20)
  """
  def list_all_comments(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    resource_type = Keyword.get(opts, :resource_type)
    status = Keyword.get(opts, :status)
    user_uuid = Keyword.get(opts, :user_uuid)
    search = Keyword.get(opts, :search)

    query =
      from(c in Comment,
        order_by: [desc: c.inserted_at],
        preload: [:user, :parent]
      )

    query =
      if resource_type, do: where(query, [c], c.resource_type == ^resource_type), else: query

    query = if status, do: where(query, [c], c.status == ^status), else: query
    query = maybe_filter_by_user(query, user_uuid)

    query =
      if search && String.trim(search) != "" do
        trimmed = String.trim(search)
        pattern = "%#{escape_like_pattern(trimmed)}%"

        # A full comment uuid matches that exact comment (so a reply can deep-link
        # to its parent by searching its uuid); otherwise it's a content search.
        if match?({:ok, _}, Ecto.UUID.cast(trimmed)) do
          where(query, [c], c.uuid == ^trimmed or ilike(c.content, ^pattern))
        else
          where(query, [c], ilike(c.content, ^pattern))
        end
      else
        query
      end

    total = repo().aggregate(query, :count)

    comments =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo().all()

    %{
      comments: comments,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: ceil(total / per_page)
    }
  end

  @doc "Returns distinct resource types that have comments."
  def list_resource_types do
    from(c in Comment, distinct: true, select: c.resource_type, order_by: c.resource_type)
    |> repo().all()
  rescue
    _ -> []
  end

  @doc "Returns comment counts grouped by resource type."
  def count_comments_by_type do
    from(c in Comment,
      group_by: c.resource_type,
      select: {c.resource_type, count(c.uuid)}
    )
    |> repo().all()
    |> Map.new()
  rescue
    e ->
      Logger.warning("Failed to load comment counts by type: #{inspect(e)}")
      %{}
  end

  @doc """
  Returns distinct metadata keys grouped by resource type.

  Queries the JSONB `metadata` column for all keys in use, e.g.:

      %{"manga_annotation" => ["chapter", "page", "slug", "source"],
        "post" => ["category"]}
  """
  def list_metadata_keys_by_type do
    from(c in Comment,
      where: c.metadata != ^%{},
      select: {c.resource_type, fragment("jsonb_object_keys(?)", c.metadata)},
      distinct: true
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {type, keys} -> {type, Enum.sort(keys)} end)
  rescue
    e ->
      Logger.warning("Failed to load metadata keys by type: #{inspect(e)}")
      %{}
  end

  @doc "Returns aggregate statistics for all comments."
  def comment_stats do
    %{
      total: count_all_comments(),
      published: count_all_comments(status: "published"),
      pending: count_all_comments(status: "pending"),
      hidden: count_all_comments(status: "hidden"),
      deleted: count_all_comments(status: "deleted")
    }
  end

  # ============================================================================
  # Comment Attachments
  # ============================================================================

  @doc """
  Attaches an uploaded file to a comment.

  `position` defaults to 1; the caller is responsible for assigning
  non-colliding positions (the DB has a unique constraint on
  `(comment_uuid, position)`).
  """
  @spec attach_media(UUIDv7.t(), UUIDv7.t(), keyword()) ::
          {:ok, CommentMedia.t()} | {:error, Ecto.Changeset.t()}
  def attach_media(comment_uuid, file_uuid, opts \\ []) do
    position = Keyword.get(opts, :position, 1)
    caption = Keyword.get(opts, :caption)

    %CommentMedia{}
    |> CommentMedia.changeset(%{
      comment_uuid: comment_uuid,
      file_uuid: file_uuid,
      position: position,
      caption: caption
    })
    |> repo().insert()
  end

  @doc "Detaches a media row by `(comment_uuid, file_uuid)`."
  def detach_media(comment_uuid, file_uuid) do
    case repo().get_by(CommentMedia, comment_uuid: comment_uuid, file_uuid: file_uuid) do
      nil -> {:error, :not_found}
      media -> repo().delete(media)
    end
  end

  @doc "Detaches a media row by its own uuid."
  def detach_media_by_uuid(media_uuid) do
    case repo().get(CommentMedia, media_uuid) do
      nil -> {:error, :not_found}
      media -> repo().delete(media)
    end
  end

  @doc "Lists media for a comment, ordered by `position`."
  def list_comment_media(comment_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:file])

    from(m in CommentMedia,
      where: m.comment_uuid == ^comment_uuid,
      order_by: [asc: m.position]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Resource Path Templates
  # ============================================================================

  @doc """
  Gets configured resource templates (path + optional display title).

  Returns a map of `resource_type => config`, where config is either:
  - A plain string (legacy path-only format)
  - A map with `"path"` and optional `"title"` keys

  ## Examples

      %{"shoes" => "/order/shoes/:uuid"}
      %{"shoes" => %{"path" => "/order/shoes/:uuid", "title" => ":metadata.name"}}
  """
  def get_resource_path_templates do
    Settings.get_json_setting("comment_resource_paths", %{})
  rescue
    e ->
      Logger.warning("Failed to load resource path templates: #{inspect(e)}")
      %{}
  end

  @doc """
  Updates resource templates for resource types.

  Accepts both legacy string values and new map values with `"path"` and `"title"` keys.
  """
  def update_resource_path_templates(templates) when is_map(templates) do
    Settings.update_json_setting("comment_resource_paths", templates)
  end

  # ============================================================================
  # Resource Resolution (for admin UI)
  # ============================================================================

  @doc """
  Resolves resource context (title and admin path) for a list of comments.

  Returns a map of `{resource_type, resource_uuid} => %{title: ..., path: ...}`
  by delegating to registered `comment_resource_handlers` that implement
  `resolve_comment_resources/1`.
  """
  def resolve_resource_context(comments) do
    comments
    |> Enum.group_by(& &1.resource_type)
    |> Enum.reduce(%{}, fn {resource_type, type_comments}, acc ->
      resolved = resolve_for_type(resource_type, type_comments)

      Enum.reduce(resolved, acc, fn {id, info}, inner ->
        Map.put(inner, {resource_type, id}, info)
      end)
    end)
  end

  defp resource_handlers do
    configured = Application.get_env(:phoenix_kit, :comment_resource_handlers, %{})
    Map.merge(default_resource_handlers(), configured)
  end

  defp default_resource_handlers do
    handlers = %{}

    handlers =
      if Code.ensure_loaded?(PhoenixKitPosts),
        do: Map.put(handlers, "post", PhoenixKitPosts),
        else: handlers

    # File comments (incl. Etcher annotation discussions) resolve to the file's
    # media page via phoenix_kit core's Annotations context.
    handlers =
      if Code.ensure_loaded?(PhoenixKit.Annotations),
        do: Map.put(handlers, "file", PhoenixKit.Annotations),
        else: handlers

    # User comments resolve to the user's admin detail page (with avatar) via
    # phoenix_kit core's Users context.
    handlers =
      if Code.ensure_loaded?(PhoenixKit.Users.CommentResources),
        do: Map.put(handlers, "user", PhoenixKit.Users.CommentResources),
        else: handlers

    handlers
  end

  defp resolve_for_type(resource_type, comments) do
    resource_uuids = comments |> Enum.map(& &1.resource_uuid) |> Enum.uniq()

    case resolve_via_handler(resource_type, resource_uuids) do
      result when map_size(result) > 0 ->
        Map.new(result, fn {id, info} -> {id, Map.put(info, :prefixed, true)} end)

      _ ->
        resolve_via_path_template(resource_type, comments)
    end
  rescue
    e ->
      Logger.warning("Comment resource resolver error: #{inspect(e)}")
      %{}
  end

  defp resolve_via_handler(resource_type, resource_uuids) do
    handlers = resource_handlers()

    case Map.get(handlers, resource_type) do
      nil ->
        %{}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve_comment_resources, 1) do
          mod.resolve_comment_resources(resource_uuids)
        else
          %{}
        end
    end
  end

  defp resolve_via_path_template(resource_type, comments) do
    templates = get_resource_path_templates()

    case Map.get(templates, resource_type) do
      nil ->
        %{}

      config ->
        path_template = path_from_config(config)
        title_template = title_from_config(config)

        Map.new(comments, fn comment ->
          metadata = comment.metadata || %{}
          path = apply_path_template(path_template, comment.resource_uuid, metadata)
          title = resolve_title(title_template, resource_type, comment, metadata)
          full_title = resolve_full_title(title_template, resource_type, comment, metadata)

          {comment.resource_uuid,
           %{title: title, full_title: full_title, path: path, prefixed: false}}
        end)
    end
  end

  defp resolve_title(nil, resource_type, comment, _metadata) do
    short_id = comment.resource_uuid |> to_string() |> String.slice(0..7)
    "#{resource_type} #{short_id}..."
  end

  defp resolve_title(title_template, _resource_type, comment, metadata) do
    apply_title_template(title_template, comment.resource_uuid, metadata)
  end

  defp resolve_full_title(nil, resource_type, comment, _metadata) do
    "#{resource_type} #{comment.resource_uuid}"
  end

  defp resolve_full_title(title_template, _resource_type, comment, metadata) do
    title_template
    |> replace_metadata_placeholders(metadata)
    |> String.replace(":uuid", to_string(comment.resource_uuid))
  end

  defp path_from_config(config) when is_binary(config), do: config
  defp path_from_config(%{"path" => path}), do: path
  defp path_from_config(_), do: ""

  defp title_from_config(config) when is_binary(config), do: nil
  defp title_from_config(%{"title" => ""}), do: nil
  defp title_from_config(%{"title" => title}), do: title
  defp title_from_config(_), do: nil

  defp apply_path_template(template, resource_uuid, metadata) do
    template
    |> replace_metadata_url_placeholders(metadata)
    |> String.replace(":prefix", prefix_value())
    |> String.replace(":uuid", url_encode(to_string(resource_uuid)))
  end

  defp apply_title_template(template, resource_uuid, metadata) do
    template
    |> replace_metadata_truncated(metadata)
    |> String.replace(":uuid", truncate_value(to_string(resource_uuid)))
  end

  defp prefix_value do
    prefix = Routes.url_prefix()
    if prefix == "/", do: "", else: prefix
  end

  defp replace_metadata_placeholders(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string()
    end)
  end

  defp replace_metadata_url_placeholders(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string() |> url_encode()
    end)
  end

  defp replace_metadata_truncated(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string() |> truncate_value()
    end)
  end

  defp url_encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @metadata_max_display_length 15

  defp truncate_value(value) do
    if String.length(value) <= @metadata_max_display_length do
      value
    else
      String.slice(value, 0, @metadata_max_display_length) <> "..."
    end
  end

  # ============================================================================
  # Like Operations
  # ============================================================================

  @doc """
  User likes a comment. Removes any existing dislike first.

  Returns `{:ok, :liked}` when a new like row was created, or
  `{:ok, :already_liked}` when the user had already liked the comment.
  """
  def like_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    result =
      repo().transaction(fn ->
        maybe_remove_reaction(CommentDislike, comment_uuid, user_uuid, :dislike_count)

        if insert_reaction(CommentLike, comment_uuid, user_uuid, :like_count) do
          :liked
        else
          :already_liked
        end
      end)

    after_reaction(result, comment_uuid, user_uuid)
    result
  end

  @doc """
  User unlikes a comment. Deletes the like row and decrements the counter
  atomically. Returns `{:ok, :unliked}` or `{:error, :not_found}`.
  """
  def unlike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    if maybe_remove_reaction(CommentLike, comment_uuid, user_uuid, :like_count) do
      result = {:ok, :unliked}
      after_reaction(result, comment_uuid, user_uuid)
      result
    else
      {:error, :not_found}
    end
  end

  @doc "Checks if a user has liked a comment."
  def comment_liked_by?(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().exists?(
      from(l in CommentLike, where: l.comment_uuid == ^comment_uuid and l.user_uuid == ^user_uuid)
    )
  end

  @doc "Lists all likes for a comment."
  def list_comment_likes(comment_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(l in CommentLike,
      where: l.comment_uuid == ^comment_uuid,
      order_by: [desc: l.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc "Lists comment UUIDs from `comment_uuids` liked by `user_uuid`."
  def list_user_liked_comment_uuids(user_uuid, comment_uuids)
      when is_binary(user_uuid) and is_list(comment_uuids) do
    from(l in CommentLike,
      where: l.user_uuid == ^user_uuid and l.comment_uuid in ^comment_uuids,
      select: l.comment_uuid
    )
    |> repo().all()
  end

  # ============================================================================
  # Dislike Operations
  # ============================================================================

  @doc """
  User dislikes a comment. Removes any existing like first.

  Returns `{:ok, :disliked}` when a new dislike row was created, or
  `{:ok, :already_disliked}` when the user had already disliked the comment.
  """
  def dislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    result =
      repo().transaction(fn ->
        maybe_remove_reaction(CommentLike, comment_uuid, user_uuid, :like_count)

        if insert_reaction(CommentDislike, comment_uuid, user_uuid, :dislike_count) do
          :disliked
        else
          :already_disliked
        end
      end)

    after_reaction(result, comment_uuid, user_uuid)
    result
  end

  @doc """
  User removes dislike from a comment. Deletes the dislike row and
  decrements the counter atomically. Returns `{:ok, :undisliked}` or
  `{:error, :not_found}`.
  """
  def undislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    if maybe_remove_reaction(CommentDislike, comment_uuid, user_uuid, :dislike_count) do
      result = {:ok, :undisliked}
      after_reaction(result, comment_uuid, user_uuid)
      result
    else
      {:error, :not_found}
    end
  end

  @doc "Checks if a user has disliked a comment."
  def comment_disliked_by?(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().exists?(
      from(d in CommentDislike,
        where: d.comment_uuid == ^comment_uuid and d.user_uuid == ^user_uuid
      )
    )
  end

  @doc "Lists all dislikes for a comment."
  def list_comment_dislikes(comment_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(d in CommentDislike,
      where: d.comment_uuid == ^comment_uuid,
      order_by: [desc: d.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc "Lists comment UUIDs from `comment_uuids` disliked by `user_uuid`."
  def list_user_disliked_comment_uuids(user_uuid, comment_uuids)
      when is_binary(user_uuid) and is_list(comment_uuids) do
    from(d in CommentDislike,
      where: d.user_uuid == ^user_uuid and d.comment_uuid in ^comment_uuids,
      select: d.comment_uuid
    )
    |> repo().all()
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_calculate_depth(attrs) do
    case Map.get(attrs, :parent_uuid) do
      nil ->
        Map.put(attrs, :depth, 0)

      parent_uuid ->
        case repo().get(Comment, parent_uuid) do
          nil -> Map.put(attrs, :depth, 0)
          parent -> Map.put(attrs, :depth, (parent.depth || 0) + 1)
        end
    end
  end

  defp build_comment_tree(comments) do
    children_by_parent = Enum.group_by(comments, & &1.parent_uuid)

    children_by_parent
    |> Map.get(nil, [])
    |> Enum.map(&add_children(&1, children_by_parent))
    |> Enum.reject(&empty_deleted?/1)
  end

  defp add_children(comment, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(comment.uuid, [])
      |> Enum.map(&add_children(&1, children_by_parent))
      |> Enum.reject(&empty_deleted?/1)

    Map.put(comment, :children, children)
  end

  defp empty_deleted?(%{status: "deleted", children: []}), do: true
  defp empty_deleted?(_), do: false

  # Insert a like/dislike via the changeset, then bump the counter.
  #
  # NOTE: we deliberately do NOT use `insert_all` with
  # `on_conflict: :nothing, conflict_target: [:comment_uuid, :user_uuid]`.
  # The likes/dislikes tables have no composite unique index on
  # (comment_uuid, user_uuid) — the original UNIQUE(comment_id, user_id)
  # was dropped when the integer `user_id` column was removed during the
  # uuid-FK migration, and nothing recreates it on `user_uuid`. With no
  # matching index, `ON CONFLICT (comment_uuid, user_uuid)` raises
  # Postgrex "no unique or exclusion constraint matching" on every
  # insert. The `reaction_exists?/3` precheck is therefore the dedup.
  defp insert_reaction(schema, comment_uuid, user_uuid, counter_field) do
    if reaction_exists?(schema, comment_uuid, user_uuid) do
      false
    else
      schema
      |> struct()
      |> schema.changeset(%{comment_uuid: comment_uuid, user_uuid: user_uuid})
      |> repo().insert()
      |> case do
        {:ok, _reaction} ->
          increment_comment_counter(comment_uuid, counter_field)
          true

        {:error, _changeset} ->
          false
      end
    end
  end

  defp reaction_exists?(schema, comment_uuid, user_uuid) do
    repo().exists?(
      from(r in schema,
        where: r.comment_uuid == ^comment_uuid and r.user_uuid == ^user_uuid
      )
    )
  end

  defp maybe_remove_reaction(schema, comment_uuid, user_uuid, counter_field) do
    {count, _} =
      from(r in schema,
        where: r.comment_uuid == ^comment_uuid and r.user_uuid == ^user_uuid
      )
      |> repo().delete_all()

    if count > 0 do
      decrement_comment_counter(comment_uuid, counter_field)
      true
    else
      false
    end
  end

  defp increment_comment_counter(comment_uuid, :like_count) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [like_count: 1])
  end

  defp increment_comment_counter(comment_uuid, :dislike_count) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [dislike_count: 1])
  end

  defp decrement_comment_counter(comment_uuid, :like_count) do
    from(c in Comment, where: c.uuid == ^comment_uuid and c.like_count > 0)
    |> repo().update_all(inc: [like_count: -1])
  end

  defp decrement_comment_counter(comment_uuid, :dislike_count) do
    from(c in Comment, where: c.uuid == ^comment_uuid and c.dislike_count > 0)
    |> repo().update_all(inc: [dislike_count: -1])
  end

  defp count_all_comments(opts \\ []) do
    status = Keyword.get(opts, :status)
    query = from(c in Comment)
    query = if status, do: where(query, [c], c.status == ^status), else: query
    repo().aggregate(query, :count)
  rescue
    _ -> 0
  end

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_uuid) when is_binary(user_uuid) do
    if UUIDUtils.valid?(user_uuid) do
      where(query, [c], c.user_uuid == ^user_uuid)
    else
      query
    end
  end

  defp maybe_set_initial_status(attrs) do
    if Map.has_key?(attrs, :status) do
      attrs
    else
      if Settings.get_boolean_setting("comments_moderation", false) do
        Map.put(attrs, :status, "pending")
      else
        attrs
      end
    end
  end

  defp validate_depth(attrs) do
    max = get_max_depth()

    if (attrs[:depth] || 0) >= max do
      {:error, :max_depth_exceeded}
    else
      :ok
    end
  end

  defp validate_content_length(attrs) do
    max = get_max_length()
    content = attrs[:content] || attrs["content"] || ""

    if String.length(content) > max do
      {:error, :content_too_long}
    else
      :ok
    end
  end

  defp escape_like_pattern(pattern) do
    pattern
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ============================================================================
  # Live updates (Phoenix.PubSub)
  # ============================================================================

  @doc """
  Returns the PubSub topic for a resource's comment activity.

  Hosts rarely need this directly — use `subscribe/2` — but it's exposed so
  callers can match or build topics themselves.
  """
  @spec topic(String.t(), term()) :: String.t()
  def topic(resource_type, resource_uuid),
    do: "phoenix_kit_comments:#{resource_type}:#{resource_uuid}"

  @doc """
  Subscribes the calling process to a resource's comment activity.

  Call this from a LiveView's `mount/3` (in the connected branch) so the
  view receives cross-session updates when *any* user comments on, deletes
  from, or reacts to the resource:

      def mount(_params, _session, socket) do
        if connected?(socket), do: PhoenixKitComments.subscribe("order", order_uuid)
        {:ok, socket}
      end

      def handle_info({:comments_updated, %{action: action}}, socket) do
        # action is :created | :deleted | :reaction
        {:noreply, refresh_comment_badges(socket)}
      end

  The broadcast payload mirrors the `{:comments_updated, …}` message the
  `CommentsComponent` already sends to its own host on create/delete, so a
  host has one message contract for both local and remote updates.

  The PubSub server is resolved via `PhoenixKit.PubSubHelper` (configurable
  with `config :phoenix_kit, pubsub: MyApp.PubSub`).
  """
  @spec subscribe(String.t(), term()) :: :ok | {:error, term()}
  def subscribe(resource_type, resource_uuid) do
    PubSubHelper.subscribe(topic(resource_type, resource_uuid))
  end

  @doc "Unsubscribes the calling process from a resource's comment activity."
  @spec unsubscribe(String.t(), term()) :: :ok
  def unsubscribe(resource_type, resource_uuid) do
    Phoenix.PubSub.unsubscribe(PubSubHelper.pubsub(), topic(resource_type, resource_uuid))
  end

  # Best-effort broadcast of a comment change. Never lets a missing/unstarted
  # PubSub server break the write path that triggered it.
  defp broadcast_change(resource_type, resource_uuid, action) do
    PubSubHelper.broadcast(
      topic(resource_type, resource_uuid),
      {:comments_updated,
       %{resource_type: resource_type, resource_uuid: resource_uuid, action: action}}
    )
  rescue
    error ->
      Logger.debug("Comment change broadcast skipped: #{inspect(error)}")
      :ok
  end

  # After a reaction toggle that actually changed state, broadcast the change
  # and dispatch the matching resource-handler callback (`on_comment_liked/3`
  # and siblings) — both off a single comment lookup. The head only matches the
  # four real actions, so `{:ok, :already_liked}` (etc.) no-ops, `{:error, _}`,
  # and rollbacks fall through to the no-op clause and never touch the DB. The
  # callback payload carries `liker_uuid` because the comment row holds the
  # author, not the reacting user; self-action skipping is the host's call. The
  # whole thing is best-effort: a DB error here must not fail the (already
  # committed) reaction, so it's rescued and logged.
  defp after_reaction({:ok, action}, comment_uuid, liker_uuid)
       when action in [:liked, :unliked, :disliked, :undisliked] do
    case get_comment(comment_uuid) do
      %Comment{resource_type: resource_type, resource_uuid: resource_uuid} = comment ->
        broadcast_change(resource_type, resource_uuid, :reaction)

        notify_resource_handler(reaction_callback(action), resource_type, resource_uuid, %{
          comment: comment,
          liker_uuid: liker_uuid
        })

      nil ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Reaction broadcast/notify skipped: #{inspect(error)}")
      :ok
  end

  defp after_reaction(_result, _comment_uuid, _liker_uuid), do: :ok

  defp reaction_callback(:liked), do: :on_comment_liked
  defp reaction_callback(:unliked), do: :on_comment_unliked
  defp reaction_callback(:disliked), do: :on_comment_disliked
  defp reaction_callback(:undisliked), do: :on_comment_undisliked

  defp notify_resource_handler(callback, resource_type, resource_uuid, comment) do
    handlers = resource_handlers()

    case Map.get(handlers, resource_type) do
      nil ->
        :ok

      handler_module ->
        if Code.ensure_loaded?(handler_module) and
             function_exported?(handler_module, callback, 3) do
          apply(handler_module, callback, [resource_type, resource_uuid, comment])
        else
          :ok
        end
    end
  rescue
    error ->
      Logger.warning("Comment resource handler error: #{inspect(error)}")
      :ok
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
