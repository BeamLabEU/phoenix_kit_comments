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

  Handler modules should implement `on_comment_created/3` and `on_comment_deleted/3`.

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
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.CommentDislike
  alias PhoenixKitComments.CommentLike

  # ============================================================================
  # Module Status
  # ============================================================================

  @impl PhoenixKit.Module
  @doc "Checks if the Comments module is enabled."
  def enabled? do
    Settings.get_boolean_setting("comments_enabled", false)
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
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "comments"

  @impl PhoenixKit.Module
  def module_name, do: "Comments"

  @impl PhoenixKit.Module
  def version, do: "0.1.0"

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
  def css_sources, do: ["phoenix_kit_comments"]

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
  - `attrs` - Comment attributes (content, parent_uuid, etc.)
  """
  def create_comment(resource_type, resource_uuid, user_uuid, attrs) when is_binary(user_uuid) do
    if UUIDUtils.valid?(user_uuid) do
      do_create_comment(resource_type, resource_uuid, user_uuid, attrs)
    else
      {:error, :invalid_user_uuid}
    end
  end

  defp do_create_comment(resource_type, resource_uuid, user_uuid, attrs) do
    attrs =
      attrs
      |> Map.put(:resource_type, resource_type)
      |> Map.put(:resource_uuid, resource_uuid)
      |> Map.put(:user_uuid, user_uuid)
      |> maybe_calculate_depth()
      |> maybe_set_initial_status()

    with :ok <- validate_depth(attrs),
         :ok <- validate_content_length(attrs),
         {:ok, comment} <- %Comment{} |> Comment.changeset(attrs) |> repo().insert() do
      notify_resource_handler(:on_comment_created, resource_type, resource_uuid, comment)
      {:ok, comment}
    end
  end

  @doc """
  Updates a comment.

  ## Parameters

  - `comment` - Comment to update
  - `attrs` - Attributes to update (content, status)
  """
  def update_comment(%Comment{} = comment, attrs) do
    comment
    |> Comment.changeset(attrs)
    |> repo().update()
  end

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

  Returns all published comments organized in a tree structure.
  """
  def get_comment_tree(resource_type, resource_uuid) do
    comments =
      from(c in Comment,
        where:
          c.resource_type == ^resource_type and
            c.resource_uuid == ^resource_uuid and
            c.status == "published",
        order_by: [asc: c.inserted_at],
        preload: [:user]
      )
      |> repo().all()

    build_comment_tree(comments)
  end

  @doc """
  Lists comments for a resource (flat list).

  ## Options

  - `:preload` - Associations to preload
  - `:status` - Filter by status
  """
  def list_comments(resource_type, resource_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_uuid,
        order_by: [asc: c.inserted_at]
      )

    query = if status, do: where(query, [c], c.status == ^status), else: query

    query
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc "Counts comments for a resource."
  def count_comments(resource_type, resource_uuid, opts \\ []) do
    status = Keyword.get(opts, :status)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_uuid
      )

    query = if status, do: where(query, [c], c.status == ^status), else: query

    repo().aggregate(query, :count)
  rescue
    _ -> 0
  end

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

  @doc "Bulk-updates status for multiple comment UUIDs."
  def bulk_update_status(comment_uuids, status)
      when is_list(comment_uuids) and status in ["published", "hidden", "deleted", "pending"] do
    from(c in Comment, where: c.uuid in ^comment_uuids)
    |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])
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
        pattern = "%#{escape_like_pattern(search)}%"
        where(query, [c], ilike(c.content, ^pattern))
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
    _ -> %{}
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
  # Resource Path Templates
  # ============================================================================

  @doc """
  Gets configured URL path templates for resource types.

  Returns a map of `resource_type => path_template`, e.g.:

      %{"shoes" => "/order/shoes/:uuid", "ticket" => "/support/:uuid"}

  Templates use `:uuid` as a placeholder that gets replaced with the actual
  resource UUID when building links in the admin UI.
  """
  def get_resource_path_templates do
    Settings.get_json_setting("comment_resource_paths", %{})
  rescue
    _ -> %{}
  end

  @doc """
  Updates URL path templates for resource types.

  ## Example

      PhoenixKitComments.update_resource_path_templates(%{
        "shoes" => "/order/shoes/:uuid",
        "ticket" => "/support/tickets/:uuid"
      })
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

    handlers
  end

  defp resolve_for_type(resource_type, comments) do
    resource_uuids = comments |> Enum.map(& &1.resource_uuid) |> Enum.uniq()

    case resolve_via_handler(resource_type, resource_uuids) do
      result when map_size(result) > 0 ->
        result

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

      template ->
        Map.new(comments, fn comment ->
          metadata = comment.metadata || %{}
          path = apply_path_template(template, comment.resource_uuid, metadata)
          short_id = comment.resource_uuid |> to_string() |> String.slice(0..7)
          {comment.resource_uuid, %{title: "#{resource_type} #{short_id}...", path: path}}
        end)
    end
  end

  defp apply_path_template(template, resource_uuid, metadata) do
    template
    |> String.replace(":uuid", to_string(resource_uuid))
    |> replace_metadata_placeholders(metadata)
  end

  defp replace_metadata_placeholders(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string()
    end)
  end

  # ============================================================================
  # Like Operations
  # ============================================================================

  @doc "User likes a comment. Removes any existing dislike first."
  def like_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().transaction(fn ->
      maybe_remove_dislike(comment_uuid, user_uuid)
      do_insert_like(comment_uuid, user_uuid)
    end)
  end

  defp do_insert_like(comment_uuid, user_uuid) do
    # Check if like already exists (handles race condition)
    case repo().get_by(CommentLike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
      nil ->
        insert_new_like(comment_uuid, user_uuid)

      existing_like ->
        # Already liked, return existing record gracefully
        existing_like
    end
  end

  defp insert_new_like(comment_uuid, user_uuid) do
    case %CommentLike{}
         |> CommentLike.changeset(%{comment_uuid: comment_uuid, user_uuid: user_uuid})
         |> repo().insert() do
      {:ok, like} ->
        increment_comment_like_count(comment_uuid)
        like

      {:error, changeset} ->
        repo().rollback(changeset)
    end
  end

  @doc "User unlikes a comment. Deletes like record and decrements counter."
  def unlike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().transaction(fn ->
      case repo().get_by(CommentLike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
        nil ->
          repo().rollback(:not_found)

        like ->
          {:ok, _} = repo().delete(like)
          decrement_comment_like_count(comment_uuid)
          like
      end
    end)
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

  # ============================================================================
  # Dislike Operations
  # ============================================================================

  @doc "User dislikes a comment. Removes any existing like first."
  def dislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().transaction(fn ->
      maybe_remove_like(comment_uuid, user_uuid)
      do_insert_dislike(comment_uuid, user_uuid)
    end)
  end

  defp do_insert_dislike(comment_uuid, user_uuid) do
    # Check if dislike already exists (handles race condition)
    case repo().get_by(CommentDislike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
      nil ->
        insert_new_dislike(comment_uuid, user_uuid)

      existing_dislike ->
        # Already disliked, return existing record gracefully
        existing_dislike
    end
  end

  defp insert_new_dislike(comment_uuid, user_uuid) do
    case %CommentDislike{}
         |> CommentDislike.changeset(%{comment_uuid: comment_uuid, user_uuid: user_uuid})
         |> repo().insert() do
      {:ok, dislike} ->
        increment_comment_dislike_count(comment_uuid)
        dislike

      {:error, changeset} ->
        repo().rollback(changeset)
    end
  end

  @doc "User removes dislike from a comment. Deletes dislike record and decrements counter."
  def undislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().transaction(fn ->
      case repo().get_by(CommentDislike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
        nil ->
          repo().rollback(:not_found)

        dislike ->
          {:ok, _} = repo().delete(dislike)
          decrement_comment_dislike_count(comment_uuid)
          dislike
      end
    end)
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
  end

  defp add_children(comment, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(comment.uuid, [])
      |> Enum.map(&add_children(&1, children_by_parent))

    Map.put(comment, :children, children)
  end

  defp increment_comment_like_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [like_count: 1])
  end

  defp decrement_comment_like_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid and c.like_count > 0)
    |> repo().update_all(inc: [like_count: -1])
  end

  defp increment_comment_dislike_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [dislike_count: 1])
  end

  defp decrement_comment_dislike_count(comment_uuid) do
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

  defp maybe_remove_like(comment_uuid, user_uuid) do
    case repo().get_by(CommentLike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
      nil ->
        :ok

      like ->
        {:ok, _} = repo().delete(like)
        decrement_comment_like_count(comment_uuid)
    end
  end

  defp maybe_remove_dislike(comment_uuid, user_uuid) do
    case repo().get_by(CommentDislike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
      nil ->
        :ok

      dislike ->
        {:ok, _} = repo().delete(dislike)
        decrement_comment_dislike_count(comment_uuid)
    end
  end

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
