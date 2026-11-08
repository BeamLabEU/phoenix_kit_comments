defmodule PhoenixKitComments do
  @moduledoc """
  Standalone, resource-agnostic comments module.

  Provides polymorphic commenting for any resource type (posts, entities, tickets, etc.)
  with unlimited threading, likes/dislikes, and moderation support.

  ## Architecture

  Comments are linked to resources via `resource_type` (string) + `resource_uuid` (UUID).
  No foreign key constraints on the resource side — any module can use comments.

  ## Resource Handler Callbacks

  A module whose records are commented on names a handler per `resource_type`,
  to make those records clickable in the moderation admin and to be told when
  comments on them are created, deleted or reacted to. The registry is core's
  `PhoenixKit.ResourceLinks.handlers/0`; this module only reads it. A handler
  gets there one of three ways, later ones winning per type:

  1. Core's built-ins for the types it knows (`"post"`, `"file"`, `"user"`, …).
  2. **`resource_links/0` on the module's `PhoenixKit.Module`** — the first
     choice for a module author, because it needs no host configuration:

         def resource_links, do: %{"ticket" => MyModule.Tickets}

  3. Host config — the override, and the way in for a host app's own types
     that have no `PhoenixKit.Module`:

         config :phoenix_kit, :comment_resource_handlers, %{
           "order" => MyApp.Orders
         }

  A link is resolved per `resource_type` in this order, stopping at the first
  tier that answers: the handler's `resolve_comment_resources/1`; then a path
  template a module declared in `resource_links/0` (a string or
  `%{"path" => …, "title" => …}` instead of a module — a link with no handler
  and no events); then the host's Settings → Comments → Resource Paths
  template.

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
  * `on_comment_published(resource_type, resource_uuid, comment)` — a `pending`
    comment was approved and is now visible (fires once; a comment published on
    creation fires `on_comment_created` instead).
  * `on_comment_deleted(resource_type, resource_uuid, comment)` — comment removed.
  * `on_comment_liked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_unliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_disliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `on_comment_undisliked(resource_type, resource_uuid, %{comment: comment, liker_uuid: uuid})`
  * `moderatable_resources(resource_type, scope)` — not an event: which of the
    type's records a holder of the base `comments` key may moderate comments
    on (`:all` or resource uuids). Without it the type is invisible to them;
    see `moderation_scope/1`.

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
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
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
  @spec enabled?() :: boolean()
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
      moderation_enabled: moderation_enabled?(),
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
  @spec module_stats() :: [%{label: String.t(), value: non_neg_integer()}]
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
  @spec get_max_depth() :: pos_integer()
  def get_max_depth do
    case Integer.parse(Settings.get_setting("comments_max_depth", "10")) do
      {n, _} when n > 0 -> n
      _ -> 10
    end
  rescue
    _ -> 10
  catch
    :exit, _ -> 10
  end

  @doc "Returns the configured maximum comment length."
  # Same shape: a stored "0" here rejected every non-empty comment.
  @spec get_max_length() :: pos_integer()
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
  catch
    :exit, _ -> 4
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
  catch
    :exit, _ -> default
  end

  @doc """
  Returns `true` when new comments wait for approval (`comments_moderation`,
  default `false`).
  """
  @spec moderation_enabled?() :: boolean()
  def moderation_enabled? do
    Settings.get_boolean_setting("comments_moderation", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
  def get_giphy_api_key do
    case Settings.get_setting("comments_giphy_api_key", "") do
      key when is_binary(key) -> key
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  @doc "Returns the configured Giphy content rating (g/pg/pg-13/r)."
  @spec get_giphy_rating() :: String.t()
  def get_giphy_rating do
    # Whitelisted on READ as well as on save: the value goes into Giphy's
    # query string, and a stored value from before the settings page checked
    # it would otherwise be sent as it is.
    case Settings.get_setting("comments_giphy_rating", "g") do
      rating when rating in ~w(g pg pg-13 r) -> rating
      _ -> "g"
    end
  rescue
    _ -> "g"
  catch
    :exit, _ -> "g"
  end

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

  defp giphy_host?(url), do: giphy_url?(url)

  @doc """
  Whether `url` is served by Giphy (`giphy.com` or a subdomain of it), over
  HTTPS. The picker keeps only such GIFs, and the comment renderer shows an
  inline image from Giphy where it turns other remote images into links.
  """
  @spec giphy_url?(term()) :: boolean()
  def giphy_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)
        String.ends_with?(host, ".giphy.com") or host == "giphy.com"

      _ ->
        false
    end
  end

  def giphy_url?(_), do: false

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
  def migration_module, do: PhoenixKitComments.Migrations

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`: the generated module PhoenixKitComments.ExpectedSchema
  (hidden from these docs; `lib/phoenix_kit_comments/expected_schema.ex`).
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKitComments.ExpectedSchema

  @doc """
  The columns of this module's tables that point at a stored file, so core's
  orphan-file check never takes a comment attachment for an orphan; see
  `PhoenixKitComments.FileReferences`.
  """
  @impl PhoenixKit.Module
  def file_references, do: PhoenixKitComments.FileReferences.pairs()

  @impl PhoenixKit.Module
  def permission_metadata do
    # Core shows the labels (not the descriptions) translated, the label
    # being the msgid against `gettext_backend:`; sub-permission labels
    # inherit it. `gettext_noop/1` puts each label in this module's catalog.
    %{
      key: "comments",
      label: gettext_noop("Comments"),
      icon: "hero-chat-bubble-left-right",
      description: "Moderate comments on records you manage",
      gettext_backend: PhoenixKitComments.Gettext,
      gettext_domain: "default",
      # The base key used to mean "moderate every comment on the site and
      # change the module's settings". It now means "moderate comments on the
      # records you manage" (each resource handler's `moderatable_resources/2`
      # answers which), and these two carry the rest. Core auto-grants
      # declared sub-keys to Admin at boot, Owner holds everything, and
      # `migrate_legacy/0` hands both once to every role that held the base
      # key before the split — so nobody loses access, while a role granted
      # the base key from now on gets only the narrow meaning.
      sub_permissions: [
        %{
          key: "moderate_all",
          label: gettext_noop("Moderate every comment on the site"),
          description:
            "See, approve, hide, delete and restore every comment, whoever's record it is on, and see authors' emails"
        },
        %{
          key: "settings",
          label: gettext_noop("Change the comments settings"),
          description:
            "Open the comments settings page: the on/off switch, moderation, limits, the Giphy API key and resource paths"
        }
      ]
    }
  end

  @moderate_all_permission "comments.moderate_all"
  @settings_permission "comments.settings"

  # One flag per sub-key, so a later sub-key gets its own pass.
  @moderate_all_backfill_key "comments_moderate_all_backfilled"
  @settings_backfill_key "comments_settings_backfilled"

  @doc """
  One-time data repairs for installs that predate a change here. Core calls
  this on every boot, so each repair carries its own "already done" flag.

    * `comments.moderate_all` and `comments.settings` are granted ONCE to
      every role that holds the base `comments` key, preserving what the
      base key allowed before the split.

  One-way and one-time: re-deciding on every boot would fight the Owner,
  handing back a permission they revoked. A role created, or granted the
  base key, after the backfill gets the narrow meaning. The flag is set only
  after every grant went through; a failure leaves it unset (and logs a
  warning) so the next boot retries.
  """
  @impl PhoenixKit.Module
  def migrate_legacy do
    results = [
      backfill_sub_permission(@moderate_all_permission, @moderate_all_backfill_key),
      backfill_sub_permission(@settings_permission, @settings_backfill_key)
    ]

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  @doc false
  # The backfill for one sub-key. `grant` is `Permissions.grant_permission/3`
  # (never a raw insert: it refreshes the affected users' live scopes); the
  # tests pass a failing one to prove the flag stays unset.
  @spec backfill_sub_permission(String.t(), String.t(), function()) :: :ok | {:error, term()}
  def backfill_sub_permission(
        sub_key,
        flag_key,
        grant \\ &Permissions.grant_permission/3
      ) do
    if Settings.get_setting(flag_key) == "true" do
      :ok
    else
      # Listed with a query that RAISES on failure. Core's
      # `roles_with_permission/1` answers `[]` for a failed query, which
      # would read as "nobody to carry over" and set the flag for good.
      failures =
        "comments"
        |> roles_holding()
        |> Enum.reject(&(sub_key in &1.keys))
        |> Enum.map(&grant.(&1.role_uuid, sub_key, nil))
        |> Enum.reject(&match?({:ok, _}, &1))

      if failures == [],
        do: save_backfill_flag(sub_key, flag_key),
        else: backfill_failed(sub_key, {:grants_failed, length(failures)})
    end
  rescue
    error -> backfill_failed(sub_key, error.__struct__)
  catch
    :exit, reason -> backfill_failed(sub_key, {:exit, exit_summary(reason)})
  end

  defp save_backfill_flag(sub_key, flag_key) do
    case Settings.update_setting_with_module(flag_key, "true", module_key()) do
      {:ok, _} -> :ok
      {:error, reason} -> backfill_failed(sub_key, {:flag_not_saved, reason})
    end
  end

  # Every role holding `base`, with every key it holds.
  defp roles_holding(base) do
    holders = from(rp in RolePermission, where: rp.module_key == ^base, select: rp.role_uuid)

    from(rp in RolePermission,
      where: rp.role_uuid in subquery(holders),
      group_by: rp.role_uuid,
      select: %{role_uuid: rp.role_uuid, keys: fragment("array_agg(?)", rp.module_key)}
    )
    |> repo().all()
  end

  defp backfill_failed(sub_key, reason) do
    Logger.warning(
      "[Comments] #{sub_key} backfill did not complete, will retry on next boot: #{inspect(reason)}"
    )

    {:error, reason}
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_comments,
        label: gettext_noop("Comments"),
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
        label: gettext_noop("Comments"),
        gettext_backend: PhoenixKitComments.Gettext,
        gettext_domain: "default",
        icon: "hero-chat-bubble-left-right",
        path: "comments",
        priority: 924,
        level: :admin,
        parent: :admin_settings,
        permission: @settings_permission,
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
  > An explicit `:status` overrides the moderation default. It is read from
  > an ATOM key only, never from a string key, and no changeset casts it
  > (`Comment.put_status/2` sets it), so forwarded form params cannot skip
  > the queue. Treat it like `:inserted_at` and `:allow_empty_content`: set
  > it from your own code, never from anything a client can influence.
  > `:depth` needs no such care — it is always recomputed from the parent.

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
    May include `:attribution` — `%{mode: "personal", label: name}` or
    `%{mode: "project", label: name, project_uuid: uuid}`, computed by
    the server (see `Comment.put_attribution/2`); never from a client.

  ## Keys

  Atom keys carry everything above. String keys — the shape of a form's
  params — are read for `"content"`, `"parent_uuid"` and `"metadata"` only,
  and every other string key is dropped, so params forwarded as they came
  can never set `:status`, `:inserted_at` or any other server-only attr. An
  atom key wins over the same string key.

  ## Returns

  `{:ok, comment}`, `{:error, changeset}`, or `{:error, reason}` with a
  reason from `precheck_create/5` or `:invalid_file_uuid`.
  """
  @spec create_comment(String.t(), term(), term(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_comment(resource_type, resource_uuid, user_uuid, attrs)
      when is_binary(user_uuid) and is_map(attrs) do
    if UUIDUtils.valid?(user_uuid) do
      do_create_comment(resource_type, resource_uuid, user_uuid, normalize_create_attrs(attrs))
    else
      {:error, :invalid_user_uuid}
    end
  end

  # A `nil` author (an anonymous viewer reaching a write) raised
  # FunctionClauseError instead of answering like a malformed one.
  def create_comment(_resource_type, _resource_uuid, _user_uuid, attrs) when is_map(attrs),
    do: {:error, :invalid_user_uuid}

  @client_attr_keys %{
    "content" => :content,
    "parent_uuid" => :parent_uuid,
    "metadata" => :metadata
  }

  # String keys used to stay as they were next to the atom keys this module
  # adds (`:resource_type`, …), and `cast/3` raises on a mixed-key map — so
  # string-keyed attrs crashed, and the `attrs["content"]` fallbacks scattered
  # through the validators were dead. Only the client-safe fields are taken
  # from string keys (see the doc above).
  defp normalize_create_attrs(attrs) do
    from_strings =
      for {key, value} <- attrs,
          is_binary(key),
          {:ok, field} <- [Map.fetch(@client_attr_keys, key)],
          into: %{},
          do: {field, value}

    atoms = for {key, value} <- attrs, is_atom(key), into: %{}, do: {key, value}

    Map.merge(from_strings, atoms)
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
  `:invalid_parent` (not a comment on this resource),
  `:max_depth_exceeded`, `:invalid_content` (not a string, or a U+0000 in
  it), `:content_too_long`, `:attachments_disabled`, `:too_many_attachments`,
  `:empty_comment`).
  """
  @spec precheck_create(String.t(), term(), term(), map(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def precheck_create(resource_type, resource_uuid, user_uuid, attrs, entry_count \\ 0)

  def precheck_create(resource_type, resource_uuid, user_uuid, attrs, entry_count)
      when is_binary(user_uuid) and is_map(attrs) and is_integer(entry_count) and
             entry_count >= 0 do
    if UUIDUtils.valid?(user_uuid) do
      prepared =
        prepare_create_attrs(
          resource_type,
          resource_uuid,
          user_uuid,
          normalize_create_attrs(attrs)
        )

      run_cheap_validators(prepared, entry_count)
    else
      {:error, :invalid_user_uuid}
    end
  end

  def precheck_create(_resource_type, _resource_uuid, _user_uuid, attrs, entry_count)
      when is_map(attrs) and is_integer(entry_count) and entry_count >= 0,
      do: {:error, :invalid_user_uuid}

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
    with :ok <- validate_parent(attrs),
         :ok <- validate_depth(attrs),
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
    |> Comment.put_status(attrs[:status])
    |> apply_backdate(attrs)
    |> Comment.put_attribution(attribution)
    |> repo().insert()
  end

  defp insert_comment_with_attachments(attrs, file_uuids, attribution) do
    repo().transaction(fn ->
      with {:ok, comment} <-
             %Comment{}
             |> Comment.changeset(attrs, has_media: true)
             |> Comment.put_status(attrs[:status])
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
    case attrs[:content] do
      content when is_binary(content) -> String.trim(content) != ""
      _ -> false
    end
  end

  defp has_giphy?(attrs) do
    metadata = attrs[:metadata] || %{}

    is_map(metadata) and
      match?(%{"url" => u} when is_binary(u) and u != "", metadata["giphy"])
  end

  @doc """
  Updates a comment.

  ## Parameters

  - `comment` - Comment to update
  - `attrs` - `content` and/or `metadata` (`Comment.update_changeset/3`;
    who wrote a comment, what it is on and its place in the thread are
    fixed at creation), and `:status` from an ATOM key only — server code
    (the moderation functions); a string `"status"` from params is ignored
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
      |> Comment.update_changeset(attrs)
      |> Comment.put_status(server_status(attrs))
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

  # `:status` only as an atom key, which only server code writes.
  defp server_status(attrs), do: Map.get(attrs, :status)

  defp ensure_media_loaded(%Comment{media: %Ecto.Association.NotLoaded{}} = comment) do
    repo().preload(comment, :media)
  end

  defp ensure_media_loaded(%Comment{} = comment), do: comment

  @doc """
  Soft-deletes a comment by setting its status to "deleted".

  Reads and locks the stored row first. One that is already deleted comes
  back as `{:error, :already_deleted}` with no side effects: re-deleting it
  used to fire `on_comment_deleted/3` again (a host keeping a count took it
  off twice), write another `comment_deleted` row and broadcast again — from
  a stale second tab, or a bulk delete over a mixed selection. A row that
  no longer exists is `{:error, :not_found}`.
  """
  @spec delete_comment(Comment.t(), keyword()) ::
          {:ok, Comment.t()}
          | {:error, :already_deleted | :not_found | Ecto.Changeset.t()}
  def delete_comment(%Comment{uuid: uuid}, opts \\ []) do
    decide = fn
      %Comment{status: "deleted"} -> {:error, :already_deleted}
      %Comment{} -> {:change, %{status: "deleted"}}
    end

    with {:ok, {:changed, deleted, _previous}} <- transition_locked(uuid, decide) do
      notify_resource_handler(
        :on_comment_deleted,
        deleted.resource_type,
        deleted.resource_uuid,
        deleted
      )

      broadcast_change(deleted.resource_type, deleted.resource_uuid, :deleted)

      Activity.log_comment({:ok, deleted}, "comments.comment_deleted", opts)
    end
  end

  # One status change, decided on the row as it is NOW: read under
  # `FOR UPDATE`, so two moderators (or a moderator and the author) acting at
  # once see each other's result instead of the struct they loaded. `decide`
  # answers `{:change, attrs}`, `:unchanged` (already in the target state —
  # nothing to write, nothing to announce) or `{:error, reason}`.
  #
  # Returns `{:ok, {:changed | :unchanged, comment, previous_status}}`. The
  # caller runs the side effects (callbacks, broadcast, audit row) only for
  # `:changed`, after the transaction has released the lock.
  defp transition_locked(uuid, decide) do
    repo().transaction(fn ->
      case repo().one(from(c in Comment, where: c.uuid == ^uuid, lock: "FOR UPDATE")) do
        nil ->
          repo().rollback(:not_found)

        %Comment{} = current ->
          apply_transition(current, decide.(current))
      end
    end)
  end

  defp apply_transition(current, {:change, attrs}) do
    case update_comment(current, attrs, log: false, broadcast: false) do
      {:ok, updated} -> {:changed, updated, current.status}
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp apply_transition(current, :unchanged), do: {:unchanged, current, current.status}
  defp apply_transition(_current, {:error, reason}), do: repo().rollback(reason)

  @doc """
  Gets a single comment by ID with optional preloads.

  Returns `nil` if not found.
  """
  @spec get_comment(term(), keyword()) :: Comment.t() | nil
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

  Raises `Ecto.NoResultsError` if not found, and `Ecto.Query.CastError` if
  `id` is not a uuid — for ids from your own code. For one from a client,
  use `get_comment/2`, which answers `nil` to both.
  """
  @spec get_comment!(String.t(), keyword()) :: Comment.t()
  def get_comment!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    Comment
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Gets nested comment tree for a resource.

  Returns all published comments organized in a tree structure. A comment
  that is not published — deleted, hidden by a moderator, or back in the
  moderation queue — is kept as a placeholder while it has published
  replies, so they stay attached and readable, and pruned otherwise. A
  hidden or pending placeholder comes with its `content` blanked and its
  `media` empty: what a moderator took down is never handed to a page.

  Only deleted comments used to be kept. A hidden one was not loaded at all,
  so hiding a comment silently took its published replies out of the thread
  — while `count_comments/3` still counted them.
  """
  @spec get_comment_tree(String.t(), term()) :: [Comment.t()]
  def get_comment_tree(resource_type, resource_uuid) do
    comments =
      from(c in Comment,
        where:
          c.resource_type == ^resource_type and
            c.resource_uuid == ^resource_uuid and
            c.status in ["published", "deleted", "hidden", "pending"],
        # The uuid settles two comments of the same instant, so turning the
        # list round (the component's `:order`) never swaps them.
        order_by: [asc: c.inserted_at, asc: c.uuid],
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
  @spec list_comments(String.t(), term(), keyword()) :: [Comment.t()]
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
    if UUIDUtils.valid?(uuid),
      do: do_update_metadata(uuid, patch),
      # As documented: a malformed id is a comment that is not there, not
      # an Ecto.Query.CastError.
      else: {:error, :not_found}
  end

  defp do_update_metadata(uuid, patch) do
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
  `match` raises `ArgumentError` rather than being treated as "everything" —
  a typo that rewrites every comment of a type is not a thing this should
  make easy.
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
  # Moderation scope
  # ============================================================================

  @typedoc """
  Which comments a moderator may see and act on, from `moderation_scope/1`.

  `:all` for a `comments.moderate_all` holder. Otherwise a rule: every
  comment of the types in `all_types`, plus, per type in `uuids`, the
  comments on those resource uuids. `%{all_types: [], uuids: %{}}` is "none".
  """
  @type moderation_scope ::
          :all | %{all_types: [String.t()], uuids: %{String.t() => [Ecto.UUID.t()]}}

  @no_comments %{all_types: [], uuids: %{}}

  @doc "The permission key that lets a moderator act on every comment."
  @spec moderate_all_permission() :: String.t()
  def moderate_all_permission, do: @moderate_all_permission

  @doc "The permission key that opens the comments settings page."
  @spec settings_permission() :: String.t()
  def settings_permission, do: @settings_permission

  @doc """
  Whether `scope` may open the moderation page at all (the base `comments`
  key). What it then sees is `moderation_scope/1`.
  """
  @spec can_moderate?(term()) :: boolean()
  def can_moderate?(%Scope{} = scope), do: Scope.can?(scope, "comments")
  def can_moderate?(_), do: false

  @doc "Whether `scope` moderates every comment on the site (`comments.moderate_all`)."
  @spec can_moderate_all?(term()) :: boolean()
  def can_moderate_all?(%Scope{} = scope), do: Scope.can?(scope, @moderate_all_permission)
  def can_moderate_all?(_), do: false

  @doc """
  Whether `scope` may open and change the comments settings
  (`comments.settings`).

  Not `Scope.can?/2`: that also requires the module to be ENABLED, and this
  answers "may this person change the comments settings", which does not
  depend on it. Held means held directly (or through the `"*"` wildcard)
  together with its base key.

  This is the page's OWN check. Core's admin gate refuses a module's admin
  pages while the module is off, so a site that switched comments off
  switches them back on from the Modules page, not from this one.
  """
  @spec can_change_settings?(term()) :: boolean()
  def can_change_settings?(%Scope{} = scope) do
    Scope.has_module_access?(scope, "comments") and
      Scope.has_module_access?(scope, @settings_permission)
  end

  def can_change_settings?(_), do: false

  @doc """
  The comments `scope` may moderate.

  `comments.moderate_all` → `:all`. The base key alone → for every resource
  type with a handler, that handler's `moderatable_resources/2` answer. A
  type with no handler, a handler without the callback, or one that answers
  `[]`, anything malformed, raises or exits contributes nothing: this fails
  CLOSED. There is no exception for the viewer's own comments or for any
  type (`"user"` included). No base key → none.

  Computed fresh on every call; the moderation page asks once per list
  build and once per action, so a revoked grant stops working on the next
  click.
  """
  @spec moderation_scope(term()) :: moderation_scope()
  def moderation_scope(scope) do
    cond do
      not can_moderate?(scope) -> @no_comments
      can_moderate_all?(scope) -> :all
      true -> scoped_moderation(scope)
    end
  end

  defp scoped_moderation(scope) do
    ResourceLinks.handlers()
    |> Enum.sort()
    |> Enum.reduce(@no_comments, fn {type, handler}, acc ->
      case ask_moderatable(handler, type, scope) do
        :all -> %{acc | all_types: [type | acc.all_types]}
        [] -> acc
        uuids -> %{acc | uuids: Map.put(acc.uuids, type, uuids)}
      end
    end)
  rescue
    error ->
      Logger.warning("[Comments] moderation scope unavailable: #{inspect(error.__struct__)}")
      @no_comments
  end

  defp ask_moderatable(handler, type, scope) when is_atom(handler) and is_binary(type) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :moderatable_resources, 2) do
      normalize_moderatable(handler.moderatable_resources(type, scope))
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[Comments] #{inspect(handler)}.moderatable_resources/2 raised for #{inspect(type)}: " <>
          inspect(error.__struct__)
      )

      []
  catch
    :exit, reason ->
      Logger.warning(
        "[Comments] #{inspect(handler)}.moderatable_resources/2 exited for #{inspect(type)}: " <>
          exit_summary(reason)
      )

      []

    :throw, _ ->
      []
  end

  defp ask_moderatable(_handler, _type, _scope), do: []

  defp normalize_moderatable(:all), do: :all

  # Cast here, not left to the query: one malformed element would raise
  # Ecto.Query.CastError for the whole page.
  defp normalize_moderatable(uuids) when is_list(uuids) do
    uuids
    |> Enum.flat_map(fn
      uuid when is_binary(uuid) ->
        case Ecto.UUID.cast(uuid) do
          {:ok, valid} -> [valid]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp normalize_moderatable(_), do: []

  @doc """
  Whether `scope` may moderate comments on ONE record — the moderation
  page's rule for a single `(resource_type, resource_uuid)`, asking only that
  type's handler. `comments.moderate_all` → true; the base key → the
  handler's `moderatable_resources/2` answer (fail closed); otherwise false.
  The embedded thread uses it to decide who may delete someone else's
  comment, so the thread and the moderation page agree.
  """
  @spec may_moderate_resource?(term(), String.t(), term()) :: boolean()
  def may_moderate_resource?(scope, resource_type, resource_uuid) do
    cond do
      not can_moderate?(scope) ->
        false

      can_moderate_all?(scope) ->
        true

      true ->
        handler = Map.get(ResourceLinks.handlers(), resource_type)

        case {ask_moderatable(handler, resource_type, scope), cast_uuid(resource_uuid)} do
          {:all, _} -> true
          {uuids, {:ok, uuid}} when is_list(uuids) -> uuid in uuids
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp cast_uuid(uuid) when is_binary(uuid), do: Ecto.UUID.cast(uuid)
  defp cast_uuid(_), do: :error

  @doc """
  Whether a comment on `(resource_type, resource_uuid)` falls inside a
  `moderation_scope/1` rule. Used for what the page shows beside a row (a
  reply's parent, a resource title), which must pass the same rule.
  """
  @spec moderation_allows?(moderation_scope(), String.t(), term()) :: boolean()
  def moderation_allows?(:all, _resource_type, _resource_uuid), do: true

  def moderation_allows?(%{all_types: types, uuids: uuids}, resource_type, resource_uuid) do
    resource_type in types or
      (is_binary(resource_uuid) and resource_uuid in Map.get(uuids, resource_type, []))
  end

  def moderation_allows?(_rule, _resource_type, _resource_uuid), do: false

  # The rule as a WHERE clause. Each type's uuid list is bound as ONE array
  # parameter: Ecto compiles `field in ^list` to `field = ANY($n)`, never an
  # expanded `IN ($1, $2, …)`. Keep it that way — Postgres caps a statement
  # at 65,535 parameters and a busy type can return more uuids than that
  # (the moderation tests bind 70,000).
  defp apply_moderation_scope(query, :all), do: query

  defp apply_moderation_scope(query, %{all_types: types, uuids: uuids}) do
    initial =
      if types == [],
        do: dynamic([c], false),
        else: dynamic([c], c.resource_type in ^types)

    predicate =
      Enum.reduce(uuids, initial, fn {type, list}, acc ->
        dynamic(
          [c],
          ^acc or
            (c.resource_type == ^type and c.resource_uuid in ^list)
        )
      end)

    where(query, ^predicate)
  end

  # Anything else is not a rule: fail closed.
  defp apply_moderation_scope(query, _rule), do: where(query, false)

  @doc """
  One comment by uuid, only when it falls inside `rule`
  (`moderation_scope/1`). A uuid outside the rule answers `nil`, exactly
  like a missing one, so a crafted uuid tells the caller nothing.
  """
  @spec get_comment_for_moderation(term(), moderation_scope(), keyword()) :: Comment.t() | nil
  def get_comment_for_moderation(uuid, rule, opts \\ [])

  def get_comment_for_moderation(uuid, rule, opts) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      from(c in Comment, where: c.uuid == ^uuid)
      |> apply_moderation_scope(rule)
      |> repo().one()
      |> case do
        nil -> nil
        comment -> repo().preload(comment, Keyword.get(opts, :preload, []))
      end
    end
  end

  def get_comment_for_moderation(_uuid, _rule, _opts), do: nil

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

  Reads and locks the stored row before approving, so a stale struct cannot
  republish a deleted comment or repeat the `on_comment_published/3` callback.
  """
  @spec approve_comment(Comment.t(), keyword()) ::
          {:ok, Comment.t()} | {:error, :comment_deleted | :not_found | Ecto.Changeset.t()}
  def approve_comment(%Comment{uuid: uuid}, opts \\ []) do
    decide = fn
      %Comment{status: "deleted"} -> {:error, :comment_deleted}
      %Comment{status: "published"} -> :unchanged
      %Comment{} -> {:change, %{status: "published"}}
    end

    with {:ok, result} <- transition_locked(uuid, decide) do
      after_transition(result, "comments.comment_approved", opts, &notify_published/2)
    end
  end

  # Readers see a pending comment only now (`on_comment_published/3`).
  defp notify_published(approved, "pending"),
    do:
      notify_resource_handler(
        :on_comment_published,
        approved.resource_type,
        approved.resource_uuid,
        approved
      )

  defp notify_published(_approved, _previous_status), do: :ok

  @doc """
  Restores a soft-deleted comment.

  Publishes only when the site does not moderate; otherwise it goes back to
  `pending`, because "undo a delete" should not also mean "approve". A
  comment that is not deleted is refused with `{:error, :not_deleted}`:
  "restore" used to set the status of whatever it was given, so a crafted
  restore published a hidden comment, or queued a published one again.
  """
  @spec restore_comment(Comment.t(), keyword()) ::
          {:ok, Comment.t()} | {:error, :not_deleted | :not_found | Ecto.Changeset.t()}
  def restore_comment(%Comment{uuid: uuid}, opts \\ []) do
    status = if moderation_enabled?(), do: "pending", else: "published"

    decide = fn
      %Comment{status: "deleted"} -> {:change, %{status: status}}
      %Comment{} -> {:error, :not_deleted}
    end

    with {:ok, result} <- transition_locked(uuid, decide) do
      after_transition(result, "comments.comment_restored", opts)
    end
  end

  @doc """
  Sets a comment's status to hidden.

  A deleted comment is refused with `{:error, :comment_deleted}`, as
  `approve_comment/2` refuses one: hiding it turned a deleted comment into a
  hidden one, which the moderation page then offered to Approve — the
  "approve never means undelete" rule, sidestepped in two clicks. One that
  is already hidden is returned as it is, with no side effects.
  """
  @spec hide_comment(Comment.t(), keyword()) ::
          {:ok, Comment.t()} | {:error, :comment_deleted | :not_found | Ecto.Changeset.t()}
  def hide_comment(%Comment{uuid: uuid}, opts \\ []) do
    decide = fn
      %Comment{status: "deleted"} -> {:error, :comment_deleted}
      %Comment{status: "hidden"} -> :unchanged
      %Comment{} -> {:change, %{status: "hidden"}}
    end

    with {:ok, result} <- transition_locked(uuid, decide) do
      after_transition(result, "comments.comment_hidden", opts)
    end
  end

  # The side effects of a moderation transition, once its lock is released:
  # broadcast, the audit row, then `extra` (a handler callback). None of
  # them for `:unchanged` — approving a published comment twice wrote a
  # second `comment_approved` row and broadcast again.
  defp after_transition(result, action, opts, extra \\ fn _comment, _previous -> :ok end)

  defp after_transition({:unchanged, comment, _previous}, _action, _opts, _extra),
    do: {:ok, comment}

  defp after_transition({:changed, comment, previous}, action, opts, extra) do
    if Keyword.get(opts, :broadcast, true),
      do: broadcast_change(comment.resource_type, comment.resource_uuid, :updated)

    result = Activity.log_comment({:ok, comment}, action, opts)
    extra.(comment, previous)
    result
  end

  @doc """
  Bulk-updates status for multiple comment UUIDs.

  Each row goes through the single-row function for its status, so a bulk
  change means exactly what the same change on one row means — the same
  refusals, callbacks and audit action:

    * `"published"` — `approve_comment/2` (refuses a deleted comment, fires
      `on_comment_published/3` for a pending one, logs `comment_approved`)
    * `"hidden"` — `hide_comment/2`
    * `"deleted"` — `delete_comment/2`
    * `"pending"` — back to the moderation queue (refuses a deleted comment;
      logs `comment_updated`)

  It used to write the status directly for all but `"deleted"`: it
  published DELETED comments, skipped `on_comment_published/3` and logged
  `comment_updated` for an approval.

  Returns `{ok_count, error_count}`. `moderation: rule` (`moderation_scope/1`,
  default `:all`) limits the rows touched; one outside it is skipped like a
  missing one.
  """
  @spec bulk_update_status([term()], String.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def bulk_update_status(comment_uuids, status, opts \\ [])

  def bulk_update_status(comment_uuids, status, opts)
      when is_list(comment_uuids) and status in ["published", "hidden", "deleted", "pending"] do
    {rule, opts} = Keyword.pop(opts, :moderation, :all)

    comment_uuids
    |> load_for_bulk(rule)
    |> Enum.reduce({0, 0}, fn comment, {ok, err} ->
      tally(set_status(comment, status, opts), ok, err)
    end)
  end

  defp set_status(comment, "published", opts), do: approve_comment(comment, opts)
  defp set_status(comment, "hidden", opts), do: hide_comment(comment, opts)
  defp set_status(comment, "deleted", opts), do: delete_comment(comment, opts)

  defp set_status(%Comment{uuid: uuid}, "pending", opts) do
    decide = fn
      %Comment{status: "deleted"} -> {:error, :comment_deleted}
      %Comment{status: "pending"} -> :unchanged
      %Comment{} -> {:change, %{status: "pending"}}
    end

    with {:ok, result} <- transition_locked(uuid, decide) do
      after_transition(result, "comments.comment_updated", opts)
    end
  end

  @doc """
  Approves every listed comment, as `approve_comment/2` does one — the same
  as `bulk_update_status(uuids, "published", opts)`.

  Deleted rows come back from `approve_comment/2` as `{:error,
  :comment_deleted}` and are counted as failures rather than silently
  skipped, so the flash tells the truth about a mixed selection.

  Returns `{approved_count, failed_count}`. Takes `moderation: rule` like
  `bulk_update_status/3`.
  """
  @spec bulk_approve([term()], keyword()) :: {non_neg_integer(), non_neg_integer()}
  def bulk_approve(comment_uuids, opts \\ []) when is_list(comment_uuids),
    do: bulk_update_status(comment_uuids, "published", opts)

  @doc """
  Hides every listed comment, as `hide_comment/2` does one — the same as
  `bulk_update_status(uuids, "hidden", opts)`. Deleted rows count as
  failures.

  Returns `{hidden_count, failed_count}`. Takes `moderation: rule` like
  `bulk_update_status/3`.
  """
  @spec bulk_hide([term()], keyword()) :: {non_neg_integer(), non_neg_integer()}
  def bulk_hide(comment_uuids, opts \\ []) when is_list(comment_uuids),
    do: bulk_update_status(comment_uuids, "hidden", opts)

  # Filtered before the query: these arrive from the client, and one non-uuid
  # element raises Ecto.Query.CastError for the whole batch. A uuid outside
  # the moderation rule is dropped exactly like a missing one.
  defp load_for_bulk(comment_uuids, rule) do
    valid_uuids = Enum.filter(comment_uuids, &(is_binary(&1) and UUIDUtils.valid?(&1)))

    from(c in Comment, where: c.uuid in ^valid_uuids)
    |> apply_moderation_scope(rule)
    |> repo().all()
  end

  defp tally({:ok, _}, ok, err), do: {ok + 1, err}
  defp tally(_result, ok, err), do: {ok, err + 1}

  @max_page 10_000
  @max_per_page 200

  @doc """
  Lists all comments across all resource types with filters.

  ## Options

  - `:resource_type` - Filter by resource type
  - `:status` - Filter by status
  - `:user_uuid` - Filter by user
  - `:search` - Search in content
  - `:page` - Page number (default: 1)
  - `:per_page` - Items per page (default: 20)
  - `:moderation` - a `moderation_scope/1` rule (default `:all`). The
    moderation page always passes the viewer's; the rule is part of the
    query, so the count and pages are of the comments the viewer may see.
  """
  @spec list_all_comments(keyword()) :: %{
          comments: [Comment.t()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          total_pages: non_neg_integer()
        }
  def list_all_comments(opts \\ []) do
    # Clamped: `per_page: 0` raised ArithmeticError, a negative one a
    # Postgres "LIMIT must not be negative", and `?page=99999999999999999999`
    # an offset too large to encode — all from values a URL can carry.
    page = opts |> Keyword.get(:page, 1) |> clamp_int(1, @max_page)
    per_page = opts |> Keyword.get(:per_page, 20) |> clamp_int(1, @max_per_page)
    resource_type = Keyword.get(opts, :resource_type)
    status = Keyword.get(opts, :status)
    user_uuid = Keyword.get(opts, :user_uuid)
    search = Keyword.get(opts, :search)

    query =
      from(c in Comment,
        order_by: [desc: c.inserted_at, desc: c.uuid],
        preload: [:user, :parent]
      )
      |> apply_moderation_scope(Keyword.get(opts, :moderation, :all))

    query =
      if resource_type, do: where(query, [c], c.resource_type == ^resource_type), else: query

    query = if status, do: where(query, [c], c.status == ^status), else: query
    query = maybe_filter_by_user(query, user_uuid)

    query =
      if is_binary(search) and search_term(search) != "" do
        trimmed = search_term(search)
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

  @doc """
  Returns distinct resource types that have comments, limited to `rule`
  (`moderation_scope/1`, default `:all`), so the filter never names a type
  the viewer has no comment on.
  """
  @spec list_resource_types(moderation_scope()) :: [String.t()]
  def list_resource_types(rule \\ :all) do
    from(c in Comment, distinct: true, select: c.resource_type, order_by: c.resource_type)
    |> apply_moderation_scope(rule)
    |> repo().all()
  rescue
    _ -> []
  end

  @doc "Returns comment counts grouped by resource type."
  @spec count_comments_by_type() :: %{String.t() => non_neg_integer()}
  def count_comments_by_type do
    from(c in Comment,
      group_by: c.resource_type,
      select: {c.resource_type, count(c.uuid)}
    )
    |> repo().all()
    |> Map.new()
  rescue
    e ->
      Logger.warning("Failed to load comment counts by type: " <> Exception.message(e))
      %{}
  end

  @doc """
  Returns distinct metadata keys grouped by resource type.

  Queries the JSONB `metadata` column for all keys in use, e.g.:

      %{"manga_annotation" => ["chapter", "page", "slug", "source"],
        "post" => ["category"]}
  """
  @spec list_metadata_keys_by_type() :: %{String.t() => [String.t()]}
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
      Logger.warning("Failed to load metadata keys by type: " <> Exception.message(e))
      %{}
  end

  @doc """
  Returns aggregate statistics (total and per status), limited to `rule`
  (`moderation_scope/1`, default `:all`).
  """
  @spec comment_stats(moderation_scope()) :: %{atom() => non_neg_integer()}
  def comment_stats(rule \\ :all) do
    by_status =
      from(c in Comment, group_by: c.status, select: {c.status, count(c.uuid)})
      |> apply_moderation_scope(rule)
      |> repo().all()
      |> Map.new()

    %{
      total: by_status |> Map.values() |> Enum.sum(),
      published: Map.get(by_status, "published", 0),
      pending: Map.get(by_status, "pending", 0),
      hidden: Map.get(by_status, "hidden", 0),
      deleted: Map.get(by_status, "deleted", 0)
    }
  rescue
    error ->
      Logger.warning(
        "PhoenixKitComments.comment_stats/1 failed, reporting 0: " <> Exception.message(error)
      )

      %{total: 0, published: 0, pending: 0, hidden: 0, deleted: 0}
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
  @spec detach_media(term(), term()) ::
          {:ok, CommentMedia.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def detach_media(comment_uuid, file_uuid) do
    # Validity first: `get_by/2` raises Ecto.Query.CastError on a malformed
    # uuid, where a missing row answers `:not_found`.
    with true <- uuid?(comment_uuid) and uuid?(file_uuid),
         %CommentMedia{} = media <-
           repo().get_by(CommentMedia, comment_uuid: comment_uuid, file_uuid: file_uuid) do
      repo().delete(media)
    else
      _ -> {:error, :not_found}
    end
  end

  defp uuid?(value), do: is_binary(value) and UUIDUtils.valid?(value)

  @doc "Detaches a media row by its own uuid."
  @spec detach_media_by_uuid(term()) ::
          {:ok, CommentMedia.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def detach_media_by_uuid(media_uuid) do
    with true <- uuid?(media_uuid),
         %CommentMedia{} = media <- repo().get(CommentMedia, media_uuid) do
      repo().delete(media)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Lists media for a comment, ordered by `position`."
  @spec list_comment_media(String.t(), keyword()) :: [CommentMedia.t()]
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
  @spec get_resource_path_templates() :: map()
  defdelegate get_resource_path_templates, to: ResourceLinks

  @doc """
  Updates resource templates for resource types.

  Accepts both legacy string values and new map values with `"path"` and `"title"` keys.
  """
  @spec update_resource_path_templates(map()) :: {:ok, term()} | {:error, term()}
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
  @spec resolve_resource_context([Comment.t()]) :: map()
  defdelegate resolve_resource_context(comments), to: ResourceLinks, as: :resolve

  # ============================================================================
  # Like Operations
  # ============================================================================

  @doc """
  User likes a comment. Removes any existing dislike first.

  Returns `{:ok, :liked}` when a new like row was created,
  `{:ok, :already_liked}` when the user had already liked the comment, or
  `{:error, :not_found}` / `{:error, changeset}` (an author that no longer
  exists). Removing a dislike on the way is reported to the resource
  handler as `on_comment_undisliked/3`, before `on_comment_liked/3`.
  """
  @spec like_comment(String.t(), String.t()) ::
          {:ok, :liked | :already_liked} | {:error, :not_found | Ecto.Changeset.t()}
  def like_comment(comment_uuid, user_uuid) when is_binary(user_uuid),
    do: react(comment_uuid, user_uuid, {CommentLike, :like_count, :liked}, CommentDislike)

  @doc """
  User unlikes a comment. Deletes the like row and decrements the counter
  atomically. Returns `{:ok, :unliked}` or `{:error, :not_found}`.
  """
  @spec unlike_comment(String.t(), String.t()) :: {:ok, :unliked} | {:error, :not_found}
  def unlike_comment(comment_uuid, user_uuid) when is_binary(user_uuid),
    do: unreact(comment_uuid, user_uuid, CommentLike, :unliked)

  @doc "Checks if a user has liked a comment."
  @spec comment_liked_by?(String.t(), String.t()) :: boolean()
  def comment_liked_by?(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().exists?(
      from(l in CommentLike, where: l.comment_uuid == ^comment_uuid and l.user_uuid == ^user_uuid)
    )
  end

  @doc "Lists all likes for a comment."
  @spec list_comment_likes(String.t(), keyword()) :: [CommentLike.t()]
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
  @spec list_user_liked_comment_uuids(String.t(), [term()]) :: [String.t()]
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

  Returns `{:ok, :disliked}` when a new dislike row was created,
  `{:ok, :already_disliked}` when the user had already disliked the comment,
  or `{:error, :not_found}` / `{:error, changeset}`. Removing a like on the
  way is reported as `on_comment_unliked/3`, before `on_comment_disliked/3`.
  """
  @spec dislike_comment(String.t(), String.t()) ::
          {:ok, :disliked | :already_disliked} | {:error, :not_found | Ecto.Changeset.t()}
  def dislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid),
    do: react(comment_uuid, user_uuid, {CommentDislike, :dislike_count, :disliked}, CommentLike)

  @doc """
  User removes dislike from a comment. Deletes the dislike row and
  decrements the counter atomically. Returns `{:ok, :undisliked}` or
  `{:error, :not_found}`.
  """
  @spec undislike_comment(String.t(), String.t()) :: {:ok, :undisliked} | {:error, :not_found}
  def undislike_comment(comment_uuid, user_uuid) when is_binary(user_uuid),
    do: unreact(comment_uuid, user_uuid, CommentDislike, :undisliked)

  # Every reaction path locks the COMMENT row first, before touching any
  # reaction row. `like_comment/2` used to delete the dislike row (and bump
  # the comment's counter) before its lock, while `undislike_comment/2` took
  # the comment lock first: the same user liking in one tab and undisliking
  # in another took the two locks in opposite orders, and Postgres killed one
  # with `deadlock_detected` — out of the LiveView's event handler. In a
  # probe 29 of 40 such pairs deadlocked.
  defp react(comment_uuid, user_uuid, {schema, counter, added}, opposite) do
    {opposite_counter, removed} = reaction_meta(opposite)

    result =
      repo().transaction(fn ->
        lock_comment!(comment_uuid)
        removed? = maybe_remove_reaction(opposite, comment_uuid, user_uuid, opposite_counter)

        action =
          if insert_reaction(schema, comment_uuid, user_uuid, counter),
            do: added,
            else: already(added)

        {action, removed?}
      end)

    case result do
      {:ok, {action, removed?}} ->
        # A switch is two state changes; a host keeping tallies from the
        # callbacks drifted when it heard only the second.
        callbacks = if removed?, do: [removed, action], else: [action]
        after_reaction(callbacks, comment_uuid, user_uuid)
        {:ok, action}

      {:error, _} = error ->
        error
    end
  end

  # In a transaction: the delete and the counter decrement are two
  # statements, and a crash between them orphaned the count.
  defp unreact(comment_uuid, user_uuid, schema, removed) do
    {counter, _} = reaction_meta(schema)

    result =
      repo().transaction(fn ->
        lock_comment!(comment_uuid)
        maybe_remove_reaction(schema, comment_uuid, user_uuid, counter)
      end)

    case result do
      {:ok, true} ->
        after_reaction([removed], comment_uuid, user_uuid)
        {:ok, removed}

      _ ->
        {:error, :not_found}
    end
  end

  defp reaction_meta(CommentLike), do: {:like_count, :unliked}
  defp reaction_meta(CommentDislike), do: {:dislike_count, :undisliked}

  defp already(:liked), do: :already_liked
  defp already(:disliked), do: :already_disliked

  @doc "Checks if a user has disliked a comment."
  @spec comment_disliked_by?(String.t(), String.t()) :: boolean()
  def comment_disliked_by?(comment_uuid, user_uuid) when is_binary(user_uuid) do
    repo().exists?(
      from(d in CommentDislike,
        where: d.comment_uuid == ^comment_uuid and d.user_uuid == ^user_uuid
      )
    )
  end

  @doc "Lists all dislikes for a comment."
  @spec list_comment_dislikes(String.t(), keyword()) :: [CommentDislike.t()]
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
  @spec list_user_disliked_comment_uuids(String.t(), [term()]) :: [String.t()]
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
        case parent_on_resource(parent_uuid, attrs) do
          {:ok, parent} -> Map.put(attrs, :depth, (parent.depth || 0) + 1)
          :error -> attrs |> Map.put(:depth, 0) |> Map.put(:invalid_parent, true)
        end
    end
  end

  # The parent must exist and be on the SAME resource. A reply naming a
  # comment from another record was stored under this record with a parent
  # from that one, and showed in neither thread: this one's tree has no root
  # leading to it and the other one never loads it.
  #
  # Validity first: `repo().get/2` on a malformed uuid raises
  # Ecto.Query.CastError.
  defp parent_on_resource(parent_uuid, attrs) do
    with true <- UUIDUtils.valid?(parent_uuid),
         %Comment{} = parent <- repo().get(Comment, parent_uuid),
         true <- parent.resource_type == attrs[:resource_type],
         true <- parent.resource_uuid == normalize_uuid(attrs[:resource_uuid]) do
      {:ok, parent}
    else
      _ -> :error
    end
  end

  defp validate_parent(%{invalid_parent: true}), do: {:error, :invalid_parent}
  defp validate_parent(_attrs), do: :ok

  # The canonical (lower-case) spelling of a uuid, or the value unchanged
  # when it is not one. Postgres hands uuids back lower-case, so anything
  # compared with a stored one, or built into a topic name, goes through this.
  defp normalize_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp build_comment_tree(comments) do
    children_by_parent = Enum.group_by(comments, & &1.parent_uuid)

    children_by_parent
    |> Map.get(nil, [])
    |> Enum.map(&add_children(&1, children_by_parent))
    |> Enum.reject(&placeholder_without_replies?/1)
  end

  defp add_children(comment, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(comment.uuid, [])
      |> Enum.map(&add_children(&1, children_by_parent))
      |> Enum.reject(&placeholder_without_replies?/1)

    comment
    |> Map.put(:children, children)
    |> as_placeholder()
  end

  # Pruned bottom-up, so a placeholder whose replies were all placeholders
  # without replies goes too.
  defp placeholder_without_replies?(%{status: "published"}), do: false
  defp placeholder_without_replies?(%{children: []}), do: true
  defp placeholder_without_replies?(_comment), do: false

  defp as_placeholder(%{status: status} = comment) when status in ["hidden", "pending"],
    do: %{comment | content: "", media: []}

  defp as_placeholder(comment), do: comment

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
  # Runs under the comment-row lock its caller took (`lock_comment!/1`).
  # Without it this is a check-then-insert with nothing underneath it.
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

        # Rolled back, not reported as "already liked": a failed insert (an
        # author that no longer exists) has aborted the transaction, and
        # nothing after it can commit.
        {:error, changeset} ->
          repo().rollback(changeset)
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
  #
  # A comment that does not exist rolls the transaction back as
  # `:not_found`. There is no rescue here: it used to swallow every error,
  # and inside a transaction a swallowed one only moved the failure to the
  # next statement, as a baffling "current transaction is aborted".
  defp lock_comment!(comment_uuid) do
    with true <- is_binary(comment_uuid) and UUIDUtils.valid?(comment_uuid),
         uuid when is_binary(uuid) <-
           repo().one(
             from(c in Comment,
               where: c.uuid == ^comment_uuid,
               lock: "FOR UPDATE",
               select: c.uuid
             )
           ) do
      uuid
    else
      _ -> repo().rollback(:not_found)
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

  # Clamped at zero rather than skipped: a decrement that would go negative
  # used to be dropped entirely, which left the counter ABOVE the truth (5
  # rows removed from a count of 3 kept 3).
  defp decrement_comment_counter(comment_uuid, :like_count, by) do
    from(c in Comment,
      where: c.uuid == ^comment_uuid,
      update: [set: [like_count: fragment("GREATEST(? - ?, 0)", c.like_count, ^by)]]
    )
    |> repo().update_all([])
  end

  defp decrement_comment_counter(comment_uuid, :dislike_count, by) do
    from(c in Comment,
      where: c.uuid == ^comment_uuid,
      update: [set: [dislike_count: fragment("GREATEST(? - ?, 0)", c.dislike_count, ^by)]]
    )
    |> repo().update_all([])
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

  # A filter that cannot match matches nothing. A malformed uuid used to
  # DROP the filter, so "this user's comments" listed everyone's.
  defp maybe_filter_by_user(query, user_uuid) do
    if is_binary(user_uuid) and UUIDUtils.valid?(user_uuid),
      do: where(query, [c], c.user_uuid == ^user_uuid),
      else: where(query, false)
  end

  defp clamp_int(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp_int(_n, lo, _hi), do: lo

  # A U+0000 can't be sent to Postgres in a parameter (it raises), and can't
  # be in any stored comment either, so it is dropped from a search.
  defp search_term(search), do: search |> String.replace(<<0>>, "") |> String.trim()

  defp maybe_set_initial_status(attrs) do
    if Map.has_key?(attrs, :status) do
      attrs
    else
      if moderation_enabled?() do
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
    content = attrs[:content] || ""

    # A composer submitting `comment[x]=y` instead of `comment=y` put a MAP
    # here, and `String.length/1` on it raised FunctionClauseError — killing
    # the LiveView and writing the user's draft into the crash report as a
    # side effect. Anything that is not a string is not a valid body; nor is
    # one with a U+0000, which PostgreSQL refuses by RAISING at the insert.
    cond do
      not is_binary(content) -> {:error, :invalid_content}
      String.contains?(content, <<0>>) -> {:error, :invalid_content}
      true -> check_content_length(content, max)
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
    do: "phoenix_kit_comments:#{resource_type}:#{normalize_uuid(resource_uuid)}"

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
    # The stored, lower-case spelling, in the topic (`topic/2`) and in the
    # payload: a create broadcast used the CALLER's spelling, so a subscriber
    # on the lower-case topic missed creates and heard everything else.
    resource_uuid = normalize_uuid(resource_uuid)

    PubSubHelper.broadcast(
      topic(resource_type, resource_uuid),
      {:comments_updated,
       %{resource_type: resource_type, resource_uuid: resource_uuid, action: action}}
    )
  rescue
    error ->
      Logger.debug("Comment change broadcast skipped: #{inspect(error.__struct__)}")
      :ok
  catch
    # An unstarted PubSub raises; a DEAD one exits on the registry lookup.
    # This guard exists so a missing PubSub cannot break the write path, and
    # without this clause it only half did.
    :exit, reason ->
      Logger.debug("Comment change broadcast skipped: #{exit_summary(reason)}")
      :ok
  end

  # After a reaction commits: broadcast the change, then dispatch the
  # resource-handler callback for each REAL state change in it
  # (`on_comment_liked/3` and siblings) — off a single comment lookup. The
  # callback payload carries `liker_uuid` because the comment row holds the
  # author, not the reacting user; self-action skipping is the host's call.
  #
  # `:already_liked` / `:already_disliked` still broadcast: the opposing
  # reaction may have been removed on the way, which is a counter change
  # every other subscriber has to see. They get no callback of their own (a
  # second like is not a new like).
  #
  # Best-effort throughout: the reaction is committed by the time this runs,
  # so nothing here may fail it.
  defp after_reaction(actions, comment_uuid, liker_uuid) do
    case get_comment(comment_uuid) do
      %Comment{resource_type: resource_type, resource_uuid: resource_uuid} = comment ->
        broadcast_change(resource_type, resource_uuid, :reaction)

        for action <- actions, action in [:liked, :unliked, :disliked, :undisliked] do
          notify_resource_handler(reaction_callback(action), resource_type, resource_uuid, %{
            comment: comment,
            liker_uuid: liker_uuid
          })
        end

        :ok

      nil ->
        :ok
    end
  rescue
    # The struct name only: an exception's fields carry the value it failed
    # on, here the comment.
    error ->
      Logger.warning("Reaction broadcast/notify skipped: #{inspect(error.__struct__)}")
      :ok
  catch
    # `get_comment/1` on a dead pool exits, and the exit took out the page
    # for a like that had saved fine.
    :exit, reason ->
      Logger.warning("Reaction broadcast/notify skipped: #{exit_summary(reason)}")
      :ok
  end

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
    # The struct name only, as `exit_summary/1` gives an exit's shape only: a
    # handler's `MatchError`, `CaseClauseError` or `KeyError` carries the term
    # it failed on — the comment, body included — and logging the exception
    # wrote that into production logs.
    error ->
      Logger.warning("Comment resource handler error: #{inspect(error.__struct__)}")
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
  # The inner reason gets the same treatment: a callee that crashed exits
  # with `{exception_or_atom, stacktrace}`, and a `:function_clause` frame
  # holds the call's arguments — the comment again.
  defp exit_summary({reason, {GenServer, :call, _args}}),
    do: "GenServer.call: #{exit_summary(reason)}"

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
