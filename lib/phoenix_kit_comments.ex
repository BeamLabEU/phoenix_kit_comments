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

  The contract is `PhoenixKitComments.ResourceHandler`. Adopting it is
  optional and changes nothing at runtime, but it is worth doing: dispatch is
  by `function_exported?/3`, so a misnamed or wrong-arity callback is
  indistinguishable from one you chose not to write — nothing fires, and there
  is no error anywhere to find it by. `@behaviour` turns that into a compile
  warning at the point of the mistake.

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
  - `update_comment/3` - Update a comment
  - `delete_comment/1` - Delete a comment
  - `get_comment/2`, `get_comment!/2` - Get by ID
  - `list_comments/3` - Flat list for a resource
  - `get_comment_tree/2` - Nested tree for a resource
  - `count_comments/3` - Count comments for a resource

  ### Moderation
  - `approve_comment/1` - Set status to published
  - `hide_comment/1` - Set status to hidden
  - `bulk_update_status/3` - Bulk status changes
  - `list_all_comments/1` - Cross-resource listing with filters
  - `comment_stats/0` - Aggregate statistics

  ### Like/Dislike
  - `like_comment/2`, `unlike_comment/2`, `comment_liked_by?/2`
  - `dislike_comment/2`, `undislike_comment/2`, `comment_disliked_by?/2`
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitComments.Gettext

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.ResourceLinks
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitComments.Activity
  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.CommentDislike
  alias PhoenixKitComments.CommentLike
  alias PhoenixKitComments.CommentMedia

  # Single-sourced from mix.exs at compile time; the behaviour test asserts
  # `version/0 == Mix.Project.config()[:version]`.
  @version Mix.Project.config()[:version]

  # ============================================================================
  # Module Status
  # ============================================================================

  @impl PhoenixKit.Module
  @doc "Checks if the Comments module is enabled."
  def enabled? do
    Settings.get_boolean_setting("comments_enabled", false)
  rescue
    _ -> false
  catch
    # A settings read against an unowned checkout raises, but against a DEAD
    # pool it exits — and this is the guard the whole module's "the database
    # may not be there" story rests on.
    :exit, _ -> false
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

  @doc """
  Returns stats for the module card on the admin Modules page.

  Runs `get_config/0`, which issues three `count` queries (total,
  published, pending comments). Invoked once per render of the admin
  Modules card; not cached.
  """
  def module_stats do
    config = get_config()

    [
      %{label: gettext("Total"), value: config[:total_comments] || 0},
      %{label: gettext("Published"), value: config[:published_comments] || 0},
      %{label: gettext("Pending"), value: config[:pending_comments] || 0}
    ]
  end

  @doc "Returns the configured maximum comment depth."
  # `n > 0` and a rescue, matching `get_max_attachments/0`. Without the
  # guard a stored "0" made `validate_depth/1` (`depth >= max`) reject EVERY
  # comment with "Reply nesting is too deep", and without the rescue an
  # unreachable settings store took the whole call down.
  def get_max_depth do
    case Integer.parse(Settings.get_setting("comments_max_depth", "10")) do
      {n, _} when n > 0 -> n
      _ -> 10
    end
  rescue
    _ -> 10
  end

  @doc "Returns the configured maximum comment length."
  # Same shape: a stored "0" here rejected every non-empty comment.
  def get_max_length do
    case Integer.parse(Settings.get_setting("comments_max_length", "10000")) do
      {n, _} when n > 0 -> n
      _ -> 10_000
    end
  rescue
    _ -> 10_000
  catch
    :exit, _ -> 10_000
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
  catch
    :exit, _ -> true
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
  catch
    :exit, _ -> false
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
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
        # The FEATURE gate, not just the key. `giphy_enabled?/0` requires
        # the toggle AND a key, while this required only the key — so with
        # the toggle off the picker was hidden and a crafted `giphy_search`
        # event still spent the host's Giphy quota. The hidden control was
        # never the control.
        if giphy_enabled?() do
          do_search_giphy(trimmed, opts)
        else
          {:error, :giphy_disabled}
        end
    end
  end

  defp do_search_giphy(trimmed, opts) do
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
            # The key rides in the query string, so `inspect(e)` on a
            # Req exception can write it to the log in plaintext.
            Logger.warning("[PhoenixKitComments] Giphy search failed: #{inspect(e.__struct__)}")
            {:error, :giphy_error}
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
  def version, do: @version

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
        gettext_backend: PhoenixKitComments.Gettext,
        gettext_domain: "default",
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
        gettext_backend: PhoenixKitComments.Gettext,
        gettext_domain: "default",
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

  @impl PhoenixKit.Module
  def js_sources do
    # A hook has to be in the host's LiveSocket when it is CONSTRUCTED. These
    # two used to register themselves from an inline <script> in the component
    # and settings templates, which works on a hard page load — the script runs
    # during HTML parse, before app.js snapshots window.PhoenixKitHooks — and
    # silently does nothing on a LiveView NAVIGATION, because morphdom never
    # executes an inserted <script> and the hooks map is already fixed.
    # Verified on a dev box: navigating to Settings → Comments logged
    # `unknown hook found for "InsertAtCursor"` four times and the
    # template-variable inserter was dead.
    #
    # Hook names are namespaced because the final fold is last-write-wins
    # across every module's bundle AND core's own hooks (see the callback's
    # docs) — `InsertAtCursor` was generic enough to collide.
    [
      %{
        app: :phoenix_kit_comments,
        file: "static/assets/phoenix_kit_comments.js",
        global: "PhoenixKitCommentsHooks"
      }
    ]
  end

  # ============================================================================
  # Comment CRUD
  # ============================================================================

  @doc """
  Creates a comment on a resource.

  Automatically calculates depth from parent. Invokes resource handler callback
  if configured.

  > #### `:status` is server-side only {: .warning}
  >
  > An explicit `:status` in `attrs` overrides the moderation default, so a
  > host that forwards raw user params into this function lets a commenter
  > send `status: "published"` and skip the queue entirely. Treat it like
  > `:inserted_at` and `:allow_empty_content`: set it from your own code, and
  > never from anything a client can influence. `:depth` needs no such care —
  > it is always recomputed from the parent here.

  ## Parameters

  - `resource_type` - Type of resource (e.g., "post")
  - `resource_uuid` - UUID of the resource
  - `user_uuid` - UUID of commenter
  - `attrs` - Comment attributes (content, parent_uuid, metadata, etc.).
    May include `:inserted_at` (a `DateTime`) to backdate the row — for
    server-created anchor/topic comments that should carry the timestamp of
    the thing they anchor (e.g. an annotation's creation time) rather than
    the moment the thread was lazily instantiated. Server-side callers only;
    never pass user input here.
    May include `:attachment_file_uuids` — a list of
    `PhoenixKit.Modules.Storage.File` UUIDs to attach to the new comment
    in display order. Comment insert + attachments run in one
    transaction; any attach failure rolls back the comment too.
    May include `:allow_empty_content` (`true`) to skip the
    content-or-media requirement — for a server-created anchor/topic
    comment whose visible text lives elsewhere (e.g. an annotation's own
    label rendered as the thread's decoration), so the thread doesn't
    have to duplicate that label into the comment body just to pass
    validation. Read directly off `attrs` before the changeset, like
    `:inserted_at` — server-side callers only; never pass user input
    here.
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
    # Popped BEFORE cast, like the file uuids: attribution decides what the
    # public sees and whether somebody is speaking for an organisation, so
    # it must arrive as a computed argument rather than as a castable field
    # a client could set.
    {attribution, attrs} = Map.pop(attrs, :attribution)
    file_uuids = List.wrap(file_uuids)
    attrs = prepare_create_attrs(resource_type, resource_uuid, user_uuid, attrs)

    with :ok <- run_cheap_validators(attrs, length(file_uuids)),
         :ok <- validate_file_uuid_format(file_uuids),
         {:ok, comment} <- insert_comment_with_attachments(attrs, file_uuids, attribution) do
      notify_resource_handler(:on_comment_created, resource_type, resource_uuid, comment)
      broadcast_change(resource_type, resource_uuid, :created)
      Activity.log_comment({:ok, comment}, "comments.comment_created", actor_uuid: user_uuid)
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

  defp insert_comment_with_attachments(attrs, [], attribution) do
    %Comment{}
    |> Comment.changeset(attrs,
      has_media: false,
      allow_empty: attrs[:allow_empty_content] == true
    )
    |> apply_backdate(attrs)
    |> Comment.put_attribution(attribution)
    |> repo().insert()
  end

  defp insert_comment_with_attachments(attrs, file_uuids, attribution) do
    repo().transaction(fn ->
      with {:ok, comment} <-
             %Comment{}
             |> Comment.changeset(attrs, has_media: true)
             |> apply_backdate(attrs)
             |> Comment.put_attribution(attribution)
             |> repo().insert(),
           :ok <- attach_files(comment.uuid, file_uuids) do
        repo().preload(comment, media: :file)
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  # `:inserted_at` is deliberately NOT in the changeset cast — a client can
  # never drive it through a form payload. Server-side callers opt in with a
  # real DateTime struct (anything else is ignored), and the explicit change
  # wins over Ecto's timestamp autogeneration. `updated_at` stays honest: it
  # records when the row was actually written.
  defp apply_backdate(changeset, %{inserted_at: %DateTime{} = dt}) do
    Ecto.Changeset.put_change(changeset, :inserted_at, DateTime.truncate(dt, :second))
  end

  defp apply_backdate(changeset, _attrs), do: changeset

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
      # Server-side escape hatch (paired with `:inserted_at` in spirit —
      # attrs are server-built, never a client form payload): an
      # anchor/topic comment whose visible text lives elsewhere (e.g. an
      # annotation's own label rendered as the thread's decoration) is
      # legitimately bodiless — duplicating the label into the body just
      # made every thread open by repeating itself.
      attrs[:allow_empty_content] == true -> :ok
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
  - `opts` - `:broadcast` (default `true`) — send `{:comments_updated,
    %{action: :updated}}` on the resource's topic, the same message
    create/delete send, so a host rendering a preview or count of this
    resource's comments refreshes. A caller that broadcasts its own,
    more specific action (`delete_comment/2`) passes `broadcast: false`.
    `:log` and the actor keys are forwarded to the activity log.
  """
  @spec update_comment(Comment.t(), map(), keyword()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def update_comment(%Comment{} = comment, attrs, opts \\ []) do
    # Preload :media so the changeset can infer "has media" when content
    # is being changed. Status-only updates skip the content-or-media
    # check entirely (see `Comment.changeset/3`), so this is a no-op on
    # moderation paths if `:media` is already loaded; but we ensure it
    # for content edits because the caller may pass a bare struct from
    # `get_comment/1`.
    result =
      comment
      |> ensure_media_loaded()
      |> Comment.changeset(attrs)
      |> repo().update()
      |> Activity.log_comment("comments.comment_updated", opts)

    # An edit — of the body or of the status (approve/hide/restore) —
    # changes what a subscriber shows just as much as a create or delete
    # does; before this every other session, and any host preview, kept
    # the old text until a reload.
    with {:ok, updated} <- result do
      if Keyword.get(opts, :broadcast, true),
        do: broadcast_change(updated.resource_type, updated.resource_uuid, :updated)

      {:ok, updated}
    end
  end

  defp ensure_media_loaded(%Comment{media: %Ecto.Association.NotLoaded{}} = comment) do
    repo().preload(comment, :media)
  end

  defp ensure_media_loaded(%Comment{} = comment), do: comment

  @doc """
  Soft-deletes a comment by setting its status to "deleted".

  Invokes resource handler callback if configured.
  """
  def delete_comment(%Comment{} = comment, opts \\ []) do
    # `update_comment/3` logs its own generic edit; the delete is the
    # meaningful line, so the inner call is left unlogged.
    case update_comment(comment, %{status: "deleted"}, log: false, broadcast: false) do
      {:ok, deleted} ->
        notify_resource_handler(
          :on_comment_deleted,
          comment.resource_type,
          comment.resource_uuid,
          deleted
        )

        broadcast_change(comment.resource_type, comment.resource_uuid, :deleted)

        Activity.log_comment({:ok, deleted}, "comments.comment_deleted", opts)

      error ->
        error
    end
  end

  @doc """
  Gets a single comment by ID with optional preloads.

  Returns `nil` if not found.
  """
  def get_comment(id, opts \\ [])

  # Callers pass raw `phx-value-uuid` straight in. `Repo.get/2` on a
  # malformed uuid raises Ecto.Query.CastError, which kills the LiveView —
  # and `save_edit` reads `socket.assigns.editing_uuid`, which is nil when
  # no edit is open, so `Repo.get(Comment, nil)` raised ArgumentError. User
  # uuids and file uuids on these same paths were already validated; comment
  # uuids were the gap. "Not a uuid" and "no such comment" are the same
  # answer to a caller.
  def get_comment(id, _opts) when not is_binary(id), do: nil

  def get_comment(id, opts) do
    if UUIDUtils.valid?(id) do
      preloads = Keyword.get(opts, :preload, [])

      case repo().get(Comment, id) do
        nil -> nil
        comment -> repo().preload(comment, preloads)
      end
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
  - `:metadata` - Map of `metadata` keys that must match, compared as text

  ## Listing across a whole resource type

  Pass `:any` as the resource uuid to drop the per-resource condition. This
  exists because `resource_uuid` is a UUID column, and plenty of hosts key
  their comments on something that isn't one — a `(source, slug, chapter)`
  triple, say. Those hosts mint a throwaway uuid per comment and put the real
  key in `metadata`, at which point every listing they actually want is "this
  type, where metadata says X" — a query the API could not express, so they
  dropped to schemaless SQL against the table and inherited its sharp edges
  (uuid columns load as 16-byte binaries there, which fails string comparison
  silently).

      # every comment of this type for one manga, whatever chapter
      list_comments("chapter", :any, metadata: %{"source" => "mangadex", "slug" => slug})

  Metadata is compared with `->>`, i.e. as text, so match against the string
  form of whatever was stored.
  """
  def list_comments(resource_type, resource_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    from(c in Comment, where: c.resource_type == ^resource_type, order_by: [asc: c.inserted_at])
    |> apply_resource_filter(resource_uuid)
    |> apply_metadata_filter(Keyword.get(opts, :metadata))
    |> apply_status_filter(status, include_deleted)
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Counts replies for a batch of parent comments, as a `parent_uuid => count`
  map.

  Mirrors the list form of `count_comments/3`: one grouped query, and a `0`
  entry for every uuid asked about, so a thread list renders uniformly without
  an N+1 or a hand-rolled correlated subquery.

      iex> count_replies([a, b, c])
      %{a => 2, b => 0, c => 5}

  Deleted replies are excluded unless `:status` is set explicitly or
  `include_deleted: true` is passed — the same rule the other reads follow.
  """
  @spec count_replies([Ecto.UUID.t()], keyword()) ::
          %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def count_replies(parent_uuids, opts \\ []) when is_list(parent_uuids) do
    uuids = Enum.uniq(parent_uuids)

    counts =
      from(c in Comment,
        where: c.parent_uuid in ^uuids,
        group_by: c.parent_uuid,
        select: {c.parent_uuid, count(c.uuid)}
      )
      |> apply_status_filter(
        Keyword.get(opts, :status),
        Keyword.get(opts, :include_deleted, false)
      )
      |> repo().all()
      |> Map.new()

    Map.new(uuids, fn uuid -> {uuid, Map.get(counts, uuid, 0)} end)
  rescue
    error ->
      # Degrading to zeros keeps a thread list rendering, but "0 replies" on a
      # thread that has replies is a plausible-looking wrong answer, not an
      # obviously broken one — so it has to leave a trace. Without the log
      # there is nothing anywhere to distinguish a quiet thread from a failed
      # query.
      Logger.warning(
        "PhoenixKitComments.count_replies/2 failed, reporting 0 for " <>
          "#{length(Enum.uniq(parent_uuids))} parents: #{Exception.message(error)}"
      )

      Map.new(Enum.uniq(parent_uuids), &{&1, 0})
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
    error ->
      # Same reasoning as count_replies/2: zeros keep a listing rendering, but
      # "0 comments" on a resource that has them is a plausible-looking wrong
      # answer rather than an obviously broken one, so it has to leave a trace.
      Logger.warning(
        "PhoenixKitComments.count_comments/3 failed, reporting 0 for " <>
          "#{length(Enum.uniq(resource_uuids))} #{resource_type} resources: " <>
          Exception.message(error)
      )

      Map.new(Enum.uniq(resource_uuids), &{&1, 0})
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
    error ->
      Logger.warning(
        "PhoenixKitComments.count_comments/3 failed, reporting 0 for " <>
          "#{resource_type} #{inspect(resource_uuid)}: " <> Exception.message(error)
      )

      0
  end

  defp apply_status_filter(query, nil, false), do: where(query, [c], c.status != "deleted")
  defp apply_status_filter(query, nil, true), do: query
  defp apply_status_filter(query, status, _), do: where(query, [c], c.status == ^status)

  # `:any` drops the condition entirely — see `list_comments/3` for why a
  # resource-type-wide read is a first-class thing to want.
  defp apply_resource_filter(query, :any), do: query
  defp apply_resource_filter(query, uuid), do: where(query, [c], c.resource_uuid == ^uuid)

  defp apply_metadata_filter(query, nil), do: query
  defp apply_metadata_filter(query, map) when map_size(map) == 0, do: query

  defp apply_metadata_filter(query, %{} = match) do
    Enum.reduce(match, query, fn {key, value}, acc ->
      # `->>` so the comparison is text-to-text. The alternative, containment
      # (`@>`), would need the value typed exactly as stored and would make
      # `"1"` and `1` different questions — a distinction no caller filtering
      # on a slug wants to think about.
      where(acc, [c], fragment("?->>? = ?", c.metadata, ^to_string(key), ^to_string(value)))
    end)
  end

  @doc """
  Merges `patch` into a comment's `metadata`, leaving every other key alone.

  The write is a single atomic `metadata || patch` statement, so it cannot
  lose a concurrent writer's keys the way read-modify-write does — and hosts
  do not have to hand-write jsonb to retarget a comment.

      iex> update_metadata(comment_uuid, %{"slug" => "new-slug"})
      {:ok, %Comment{}}

  Returns `{:error, :not_found}` if the row is gone.
  """
  @spec update_metadata(Ecto.UUID.t() | Comment.t(), map()) ::
          {:ok, Comment.t()} | {:error, :not_found}
  def update_metadata(%Comment{uuid: uuid}, patch), do: update_metadata(uuid, patch)

  def update_metadata(uuid, %{} = patch) when is_binary(uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(c in Comment,
        where: c.uuid == ^uuid,
        update: [
          set: [
            # COALESCE first: the column is nullable, and `NULL || jsonb` is
            # NULL — without it a null-metadata row would swallow the patch and
            # still report success.
            metadata: fragment("COALESCE(?, '{}'::jsonb) || ?", c.metadata, type(^patch, :map)),
            updated_at: ^now
          ]
        ],
        select: c
      )

    case repo().update_all(query, []) do
      {1, [comment]} -> {:ok, comment}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Merges `patch` into the metadata of every comment of `resource_type` whose
  metadata matches `match`. Returns the number of rows updated.

  This is the rename case: a host keyed on a slug renames it, and every
  comment carrying the old one has to follow. Doing that by hand means a raw
  `metadata || jsonb_build_object(...)` UPDATE in the host, which is how a
  schema this package owns ends up written to from outside it.

      iex> merge_metadata("chapter", %{"slug" => "old"}, %{"slug" => "new"})
      42

  Matching is the same text comparison `list_comments/3` uses. An empty
  `match` is refused rather than treated as "everything" — a typo that
  rewrites every comment of a type is not a thing this should make easy.
  """
  @spec merge_metadata(String.t(), map(), map()) :: non_neg_integer()
  def merge_metadata(_resource_type, match, _patch) when map_size(match) == 0 do
    raise ArgumentError,
          "merge_metadata/3 requires a non-empty match; refusing to rewrite every comment of a type"
  end

  def merge_metadata(resource_type, %{} = match, %{} = patch) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type,
        update: [
          set: [
            metadata: fragment("COALESCE(?, '{}'::jsonb) || ?", c.metadata, type(^patch, :map)),
            updated_at: ^now
          ]
        ]
      )
      |> apply_metadata_filter(match)

    {count, _} = repo().update_all(query, [])
    count
  end

  # ============================================================================
  # Moderation
  # ============================================================================

  @doc """
  Sets a comment's status to published.

  Refuses a soft-deleted comment with `{:error, :comment_deleted}`: approving
  must never mean undeleting. The row menu hides Approve on a deleted row for
  that reason, and `bulk_approve/2` counted such rows as failures — but the
  single-row handler took whatever uuid the event carried, so a replayed or
  hand-made `approve` published a deleted comment anyway. The rule belongs
  here, at the one place every caller goes through. Use `restore_comment/2`
  to bring a deleted comment back.
  """
  @spec approve_comment(Comment.t(), keyword()) ::
          {:ok, Comment.t()} | {:error, :comment_deleted | Ecto.Changeset.t()}
  def approve_comment(comment, opts \\ [])

  def approve_comment(%Comment{status: "deleted"}, _opts), do: {:error, :comment_deleted}

  def approve_comment(%Comment{} = comment, opts) do
    comment
    # `log: false` so this writes ONE audit row, not a
    # `comments.comment_updated` from the inner call plus the approval.
    # restore_comment/2 and delete_comment/2 already did this.
    |> update_comment(%{status: "published"}, Keyword.put(opts, :log, false))
    |> Activity.log_comment("comments.comment_approved", opts)
  end

  @doc """
  Restores a soft-deleted comment.

  Publishes only when the site does not moderate; otherwise it goes back to
  `pending`, because "undo a delete" should not also mean "approve".
  """
  @spec restore_comment(Comment.t(), keyword()) :: {:ok, Comment.t()} | {:error, term()}
  def restore_comment(%Comment{} = comment, opts \\ []) do
    status =
      if Settings.get_boolean_setting("comments_moderation", false),
        do: "pending",
        else: "published"

    comment
    |> update_comment(%{status: status}, Keyword.put(opts, :log, false))
    |> Activity.log_comment("comments.comment_restored", opts)
  end

  @doc "Sets a comment's status to hidden."
  def hide_comment(%Comment{} = comment, opts \\ []) do
    comment
    |> update_comment(%{status: "hidden"}, Keyword.put(opts, :log, false))
    |> Activity.log_comment("comments.comment_hidden", opts)
  end

  @doc """
  Bulk-updates status for multiple comment UUIDs.

  Routes through `update_comment/2` (and `delete_comment/1` for the
  `"deleted"` case) so resource-handler callbacks fire per row. Returns
  `{ok_count, error_count}`.
  """
  def bulk_update_status(comment_uuids, status, opts \\ [])

  def bulk_update_status(comment_uuids, status, opts)
      when is_list(comment_uuids) and status in ["published", "hidden", "deleted", "pending"] do
    # Filtered before the query: these arrive from the client, and a single
    # non-uuid element raises Ecto.Query.CastError for the whole batch.
    valid_uuids = Enum.filter(comment_uuids, &UUIDUtils.valid?/1)

    comments =
      from(c in Comment, where: c.uuid in ^valid_uuids)
      |> repo().all()

    Enum.reduce(comments, {0, 0}, fn comment, {ok, err} ->
      result =
        case status do
          "deleted" -> delete_comment(comment, opts)
          _ -> update_comment(comment, %{status: status}, opts)
        end

      case result do
        {:ok, _} -> {ok + 1, err}
        _ -> {ok, err + 1}
      end
    end)
  end

  @doc """
  Approves every listed comment, as `approve_comment/2` does one.

  Not `bulk_update_status(uuids, "published", opts)`: that writes the status
  directly, so it logs `comment_updated` rather than `comment_approved`, and
  it publishes DELETED comments — the single-row menu hides Approve on a
  deleted row precisely because "approve" must never mean "undelete".
  Deleted rows come back from `approve_comment/2` as `{:error,
  :comment_deleted}` and are counted as failures rather than silently
  skipped, so the flash tells the truth about a mixed selection.

  Returns `{approved_count, failed_count}`.
  """
  def bulk_approve(comment_uuids, opts \\ []) when is_list(comment_uuids) do
    comment_uuids
    |> load_for_bulk()
    |> Enum.reduce({0, 0}, fn comment, {ok, err} ->
      tally(approve_comment(comment, opts), ok, err)
    end)
  end

  @doc """
  Hides every listed comment, as `hide_comment/2` does one.

  Same reason as `bulk_approve/2`: the status-writing path logs
  `comment_updated`, so a bulk hide left no `comment_hidden` row behind it.

  Returns `{hidden_count, failed_count}`.
  """
  def bulk_hide(comment_uuids, opts \\ []) when is_list(comment_uuids) do
    comment_uuids
    |> load_for_bulk()
    |> Enum.reduce({0, 0}, fn comment, {ok, err} ->
      tally(hide_comment(comment, opts), ok, err)
    end)
  end

  # Same client-uuid filtering as bulk_update_status/3: one non-uuid element
  # raises Ecto.Query.CastError for the whole batch.
  defp load_for_bulk(comment_uuids) do
    valid_uuids = Enum.filter(comment_uuids, &UUIDUtils.valid?/1)

    from(c in Comment, where: c.uuid in ^valid_uuids)
    |> repo().all()
  end

  defp tally({:ok, _}, ok, err), do: {ok + 1, err}
  defp tally(_result, ok, err), do: {ok, err + 1}

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
      Logger.warning("Failed to load comment counts by type: " <> inspect(e))
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
      Logger.warning("Failed to load metadata keys by type: " <> inspect(e))
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
  defdelegate get_resource_path_templates, to: ResourceLinks

  @doc """
  Updates resource templates for resource types.

  Accepts both legacy string values and new map values with `"path"` and `"title"` keys.
  """
  defdelegate update_resource_path_templates(templates), to: ResourceLinks

  # ============================================================================
  # Resource Resolution (for admin UI)
  # ============================================================================

  @doc """
  Resolves resource context (title and admin path) for a list of comments.

  Returns a map of `{resource_type, resource_uuid} => %{title: ..., path: ...}`.
  Delegates to `PhoenixKit.ResourceLinks` (core) — the same resolver drives both
  this comments moderation admin and the Activity feed, off one set of handlers
  and the shared `comment_resource_paths` templates.
  """
  defdelegate resolve_resource_context(comments), to: ResourceLinks, as: :resolve

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
    # In a transaction like its counterpart: the delete and the counter
    # decrement are two statements, and a crash between them orphaned the
    # count. `like_comment/2` always wrapped them; this one did not.
    {:ok, removed?} =
      repo().transaction(fn ->
        lock_comment(comment_uuid)
        maybe_remove_reaction(CommentLike, comment_uuid, user_uuid, :like_count)
      end)

    if removed? do
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
    {:ok, removed?} =
      repo().transaction(fn ->
        lock_comment(comment_uuid)
        maybe_remove_reaction(CommentDislike, comment_uuid, user_uuid, :dislike_count)
      end)

    if removed? do
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
        Map.put(attrs, :depth, depth_below(parent_uuid))
    end
  end

  # Validity first: `repo().get/2` on a malformed uuid raises
  # Ecto.Query.CastError, so a bad `parent_uuid` crashed the caller instead of
  # coming back as a changeset error. Leaving it unresolved lets the insert
  # fail properly on the cast/FK.
  defp depth_below(parent_uuid) do
    with true <- UUIDUtils.valid?(parent_uuid),
         %Comment{} = parent <- repo().get(Comment, parent_uuid) do
      (parent.depth || 0) + 1
    else
      _ -> 0
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
    # Serialised on the parent comment row — see `lock_comment/1`. Without
    # it this is a check-then-insert with nothing underneath it.
    lock_comment(comment_uuid)

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

  # `SELECT ... FOR UPDATE` on the comment being reacted to.
  #
  # There is no unique index on (comment_uuid, user_uuid): the original
  # UNIQUE(comment_id, user_id) was dropped when the integer `user_id`
  # column was removed during the uuid-FK migration and nothing recreated
  # it on `user_uuid`. The schemas still declare
  # `unique_constraint(..., name: :uq_comments_likes_comment_user)` — that
  # is dead code, because Ecto only turns a DATABASE violation into a
  # changeset error and there is no database constraint to violate.
  #
  # So `reaction_exists?/3` really was the only dedup, and a SELECT then an
  # INSERT in READ COMMITTED is not one: two clicks in the same instant both
  # saw "no reaction", both inserted, and the counter went to 2 for one
  # user. Taking a row lock on the parent makes concurrent reactions to the
  # SAME comment serialise, which is exactly the scope that matters.
  #
  # Restoring the index in core's chain is still worth doing — it would make
  # this correct even for writers that bypass this function — but this
  # closes the hole without a cross-repo migration.
  defp lock_comment(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid, lock: "FOR UPDATE", select: c.uuid)
    |> repo().one()
  rescue
    # Outside a transaction Postgres refuses FOR UPDATE; the callers all run
    # inside one, but a future caller that does not should not crash.
    _ -> nil
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
      # By the number ACTUALLY deleted, not by one. There is no unique index
      # on (comment_uuid, user_uuid) — see `insert_reaction/4` — so duplicate
      # rows are reachable, and decrementing by one for an N-row delete left
      # the counter permanently above the truth with no way for a user to
      # bring it back down.
      decrement_comment_counter(comment_uuid, counter_field, count)
      true
    else
      false
    end
  end

  # One pair instead of four near-identical clauses. The counter field is
  # already an atom chosen by the caller from a closed set, so it can be
  # interpolated into the update directly.
  defp increment_comment_counter(comment_uuid, counter_field) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [{counter_field, 1}])
  end

  defp decrement_comment_counter(comment_uuid, counter_field, by) do
    # The floor still holds: `field >= by` rather than `> 0`, so a decrement
    # that would go negative is skipped entirely instead of clamping halfway.
    from(c in Comment,
      where: c.uuid == ^comment_uuid and field(c, ^counter_field) >= ^by
    )
    |> repo().update_all(inc: [{counter_field, -by}])
  end

  defp count_all_comments(opts \\ []) do
    status = Keyword.get(opts, :status)
    query = from(c in Comment)
    query = if status, do: where(query, [c], c.status == ^status), else: query
    repo().aggregate(query, :count)
  rescue
    error ->
      Logger.warning(
        "PhoenixKitComments.count_all_comments/1 failed, reporting 0" <>
          " (status=#{inspect(Keyword.get(opts, :status))}): " <> Exception.message(error)
      )

      0
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

    # A composer submitting `comment[x]=y` instead of `comment=y` put a MAP
    # here, and `String.length/1` on it raised FunctionClauseError — killing
    # the LiveView and writing the user's draft into the crash report as a
    # side effect. Anything that is not a string is not a valid body.
    if is_binary(content) do
      check_content_length(content, max)
    else
      {:error, :invalid_content}
    end
  end

  defp check_content_length(content, max) do
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
  view receives cross-session updates when *any* user comments on, edits,
  deletes from, or reacts to the resource:

      def mount(_params, _session, socket) do
        if connected?(socket), do: PhoenixKitComments.subscribe("order", order_uuid)
        {:ok, socket}
      end

      def handle_info({:comments_updated, %{action: action}}, socket) do
        # action is :created | :updated | :deleted | :reaction
        {:noreply, refresh_comment_badges(socket)}
      end

  The broadcast payload mirrors the `{:comments_updated, …}` message the
  `CommentsComponent` already sends to its own host on create/edit/delete, so a
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
  catch
    # An unstarted PubSub raises; a DEAD one exits on the registry lookup.
    # This guard exists so a missing PubSub cannot break the write path, and
    # without this clause it only half did.
    :exit, reason ->
      Logger.debug("Comment change broadcast skipped: #{inspect(reason)}")
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
  # `:already_liked` / `:already_disliked` are NOT no-ops. Both write paths
  # remove the opposing reaction before deciding, so a repeat click still
  # commits a delete and a counter change — and this clause used to skip
  # them, leaving every other subscriber showing a stale count until
  # something unrelated forced a reload.
  #
  # The host CALLBACK stays scoped to real state changes (a second like is
  # not a new like), so only the broadcast fires for the repeat case.
  defp after_reaction({:ok, action}, comment_uuid, _liker_uuid)
       when action in [:already_liked, :already_disliked] do
    case get_comment(comment_uuid) do
      %Comment{resource_type: resource_type, resource_uuid: resource_uuid} ->
        broadcast_change(resource_type, resource_uuid, :reaction)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

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
  catch
    # The reaction is already committed by the time this runs; the whole
    # point of the guard is that nothing here can fail the write. `rescue`
    # alone did not deliver that — `get_comment/1` on a dead pool exits, and
    # the exit took out the page for a like that had saved fine.
    :exit, reason ->
      Logger.warning("Reaction broadcast/notify skipped: #{inspect(reason)}")
      :ok
  end

  defp after_reaction(_result, _comment_uuid, _liker_uuid), do: :ok

  defp reaction_callback(:liked), do: :on_comment_liked
  defp reaction_callback(:unliked), do: :on_comment_unliked
  defp reaction_callback(:disliked), do: :on_comment_disliked
  defp reaction_callback(:undisliked), do: :on_comment_undisliked

  defp notify_resource_handler(callback, resource_type, resource_uuid, comment) do
    case Map.get(ResourceLinks.handlers(), resource_type) do
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
  catch
    # This applies/3 arbitrary HOST code, and it runs after the comment has
    # already committed. A handler doing a GenServer.call to a dead process
    # exits rather than raising, and the exit propagates out of
    # create_comment/4 and kills the LiveView — leaving the user looking at a
    # crashed page for a comment that was saved fine.
    :exit, reason ->
      # NOT `inspect(reason)`: a handler doing `GenServer.call(worker,
      # {:created, comment})` against a dead or slow process exits with the
      # call ARGUMENTS in the reason, so logging it verbatim writes the
      # entire comment — body, author, metadata — into production logs. The
      # shape is what a reader needs; the payload is what they must not get.
      Logger.warning("Comment resource handler exited: #{exit_summary(reason)}")
      :ok
  end

  # A one-line, payload-free description of an exit reason.
  defp exit_summary({:timeout, {GenServer, :call, _args}}), do: "GenServer.call timeout"
  defp exit_summary({:noproc, {GenServer, :call, _args}}), do: "GenServer.call to a dead process"
  defp exit_summary({reason, {GenServer, :call, _args}}), do: "GenServer.call: #{inspect(reason)}"
  defp exit_summary(:normal), do: "normal"
  defp exit_summary(:shutdown), do: "shutdown"
  defp exit_summary(reason) when is_atom(reason), do: inspect(reason)

  # Anything else: name the top-level shape only. An exception struct is
  # safe to name but not to render — its message interpolates the value.
  defp exit_summary(%{__struct__: module}), do: inspect(module)

  defp exit_summary(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    "#{inspect(elem(reason, 0))} (details omitted)"
  end

  defp exit_summary(_reason), do: "unknown reason (details omitted)"

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
