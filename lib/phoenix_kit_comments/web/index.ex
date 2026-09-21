defmodule PhoenixKitComments.Web.Index do
  @moduledoc """
  LiveView for comment moderation admin page.

  Provides cross-resource comment management with filtering, search,
  pagination, and bulk actions.

  ## Route

  Mounted at `{prefix}/admin/comments`.
  """

  use PhoenixKitWeb, :live_view
  # Rebind gettext macros to the comments module's own catalogs (priv/gettext).
  use Gettext, backend: PhoenixKitComments.Gettext

  import PhoenixKitComments.Web.Markdown, only: [comment_markdown: 1, comment_markdown_styles: 1]

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitComments.Comment
  alias PhoenixKitWeb.Actor

  @impl true
  # Reads are gated here, not only writes.
  #
  # Core's admin routes are pipelined through `:phoenix_kit_ensure_admin`
  # only; the `permission: "comments"` on the tab controls sidebar
  # VISIBILITY, not access. So every mutation called `check_authorization/1`
  # and correctly answered "Not authorized", while `mount/3`,
  # `handle_params/3` and `view_comment` handed an admin without the
  # comments permission the whole platform's comments — bodies, commenter
  # emails, and on the settings page the Giphy API key in a form value.
  # That every write was gated is what shows the read side was meant to be.
  def mount(_params, _session, socket) do
    case check_authorization(socket) do
      :ok ->
        do_mount(socket)

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not have access to comments."))
         |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp do_mount(socket) do
    if PhoenixKitComments.enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("Comments"))
        |> assign(:page_subtitle, gettext("Moderate comments across all content"))
        |> assign(:project_title, "")
        |> assign(:comments, [])
        |> assign(:total, 0)
        |> assign(:total_pages, 1)
        |> assign(:resource_context, %{})
        |> assign(:viewing_comment, nil)
        |> assign(:stats, empty_stats())
        |> assign(:resource_types, [])
        |> assign_filter_defaults()
        |> maybe_load_dashboard_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Comments module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = apply_params(socket, params)
    socket = if connected?(socket), do: load_comments(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    combined_params = %{"page" => "1"}

    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    new_params = build_url_params(socket.assigns, combined_params)
    {:noreply, push_patch(socket, to: Routes.path("/admin/comments?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/comments"))}
  end

  # Clear only the search (keep the resource-type / status filters).
  @impl true
  def handle_event("clear_search", _params, socket) do
    new_params = build_url_params(socket.assigns, %{"page" => "1", "search" => ""})
    {:noreply, push_patch(socket, to: Routes.path("/admin/comments?#{new_params}"))}
  end

  # Open / close the full-comment modal (the list view only shows a truncated
  # preview; this shows the whole comment in formatted prose).
  @impl true
  def handle_event("view_comment", %{"uuid" => uuid}, socket) do
    # The only read event that skipped the check every write performs. Mount
    # now gates the page, but this stays: it reads an ARBITRARY comment by
    # uuid, so it is the one handler where "already on the page" is not the
    # same as "may see this row".
    case check_authorization(socket) do
      :ok ->
        {:noreply,
         assign(
           socket,
           :viewing_comment,
           PhoenixKitComments.get_comment(uuid, preload: [:user, media: :file])
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  @impl true
  def handle_event("close_comment", _params, socket) do
    {:noreply, assign(socket, :viewing_comment, nil)}
  end

  @impl true
  def handle_event("approve", %{"uuid" => uuid}, socket) do
    moderate(socket, uuid, &PhoenixKitComments.approve_comment/2,
      ok: gettext("Comment approved"),
      error: gettext("Could not approve this comment")
    )
  end

  @impl true
  def handle_event("hide", %{"uuid" => uuid}, socket) do
    moderate(socket, uuid, &PhoenixKitComments.hide_comment/2,
      ok: gettext("Comment hidden"),
      error: gettext("Could not hide this comment")
    )
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    moderate(socket, uuid, &PhoenixKitComments.delete_comment/2,
      ok: gettext("Comment deleted"),
      error: gettext("Could not delete this comment")
    )
  end

  # Revert a soft-deletion. Restoring publishes only where publishing is the
  # default: with moderation ON the comment goes back to the queue rather than
  # straight onto the page, because "undo a delete" must not also mean
  # "approve" something that was never approved. That is `restore_comment/2`'s
  # whole job — this handler called `approve_comment/2` instead, which
  # publishes unconditionally, so it re-introduced exactly the bug
  # `restore_comment/2` exists to prevent (and, symmetrically, Approve called
  # `restore_comment/2` and did nothing at all under moderation).
  @impl true
  def handle_event("restore", %{"uuid" => uuid}, socket) do
    moderate(socket, uuid, &PhoenixKitComments.restore_comment/2,
      ok: gettext("Comment restored"),
      error: gettext("Could not restore this comment")
    )
  end

  @impl true
  def handle_event("bulk_approve", %{"uuids" => uuids}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      :ok ->
        do_bulk_action("approve", uuids, socket)
    end
  end

  @impl true
  def handle_event("bulk_hide", %{"uuids" => uuids}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      :ok ->
        do_bulk_action("hide", uuids, socket)
    end
  end

  @impl true
  def handle_event("bulk_delete_comments", %{"uuids" => uuids}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      :ok ->
        do_bulk_action("delete", uuids, socket)
    end
  end

  defp do_bulk_action(action, uuids, socket) do
    if uuids == [] do
      {:noreply, put_flash(socket, :error, gettext("No comments selected"))}
    else
      opts = Actor.opts(socket)

      # Each bulk action goes through the SAME context function as its
      # single-row menu item. Writing the status directly (the old
      # `bulk_update_status(uuids, "published")`) skipped the moderation
      # semantics that live in `approve_comment/2` and `hide_comment/2`: it
      # logged `comment_updated` instead of the moderation action, and bulk
      # Approve published deleted comments — the very thing the single-row
      # menu refuses to offer, and the same swap this sweep fixed one screen
      # over.
      #
      # All three return `{ok_count, error_count}`, which every branch used
      # to throw away and flash success unconditionally — so a bulk action
      # where every row failed still reported "Comments approved".
      {{ok_count, err_count}, label} =
        case action do
          "approve" -> {PhoenixKitComments.bulk_approve(uuids, opts), gettext("approved")}
          "hide" -> {PhoenixKitComments.bulk_hide(uuids, opts), gettext("hidden")}
          "delete" -> {bulk_delete(uuids, opts), gettext("deleted")}
        end

      socket = socket |> load_comments() |> reload_stats()

      {:noreply,
       put_flash(socket, bulk_flash_kind(err_count), bulk_message(ok_count, err_count, label))}
    end
  end

  # Delete already routed through `delete_comment/2` inside
  # `bulk_update_status/3`; kept on that path so its soft-delete bookkeeping
  # stays in one place.
  defp bulk_delete(uuids, opts) do
    PhoenixKitComments.bulk_update_status(uuids, "deleted", opts)
  end

  ## --- Private ---

  # Every single-row moderation action goes through here, for the reason the
  # bulk path was given the same treatment one screen over: each of these
  # four handlers threw the context's return value away and flashed success
  # unconditionally. A refused or failed moderation therefore told the admin
  # it had worked, and — `Activity.log_comment/3` only logs the `{:ok, _}`
  # clause — left nothing behind to contradict it. Now the result decides the
  # flash, and a failure is logged.
  defp moderate(socket, uuid, fun, messages) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid),
         {:ok, _updated} <- fun.(comment, Actor.opts(socket)) do
      {:noreply,
       socket
       |> load_comments()
       |> reload_stats()
       |> put_flash(:info, Keyword.fetch!(messages, :ok))}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found"))}

      {:error, reason} ->
        Logger.warning("Comment moderation failed for #{uuid}: #{failure_reason(reason)}")

        {:noreply,
         socket
         |> load_comments()
         |> reload_stats()
         |> put_flash(:error, Keyword.fetch!(messages, :error))}
    end
  end

  # The changeset itself carries the comment body; `errors` carries the
  # field, the message and the validation options and nothing else. Same
  # reason the settings-save path logs a struct name rather than
  # `Exception.message/1`.
  defp failure_reason(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp failure_reason(reason), do: inspect(reason)

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, 20)
    |> assign(:search, "")
    |> assign(:filter_resource_type, nil)
    |> assign(:filter_status, nil)
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:page, parse_int(params["page"], 1))
    |> assign(:search, params["search"] || "")
    |> assign(:filter_resource_type, blank_to_nil(params["resource_type"]))
    |> assign(:filter_status, blank_to_nil(params["status"]))
  end

  defp load_comments(socket) do
    result =
      PhoenixKitComments.list_all_comments(
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        search: socket.assigns.search,
        resource_type: socket.assigns.filter_resource_type,
        status: socket.assigns.filter_status
      )

    resource_context = PhoenixKitComments.resolve_resource_context(result.comments)

    socket
    |> assign(:comments, result.comments)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
    |> assign(:resource_context, resource_context)
    # Reloading the list (an action, filter, or navigation) closes the open
    # full-comment modal so it never shows stale content.
    |> assign(:viewing_comment, nil)
  end

  defp reload_stats(socket) do
    assign(socket, :stats, PhoenixKitComments.comment_stats())
  end

  defp maybe_load_dashboard_data(socket) do
    if connected?(socket) do
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:stats, PhoenixKitComments.comment_stats())
      |> assign(:resource_types, PhoenixKitComments.list_resource_types())
    else
      socket
    end
  end

  defp empty_stats,
    do: %{total: 0, published: 0, pending: 0, hidden: 0, deleted: 0}

  defp build_url_params(assigns, overrides) do
    params =
      %{}
      |> maybe_put("page", Map.get(overrides, "page", to_string(assigns.page)))
      |> maybe_put("search", Map.get(overrides, "search", assigns.search))
      |> maybe_put(
        "resource_type",
        Map.get(overrides, "resource_type", assigns.filter_resource_type)
      )
      |> maybe_put("status", Map.get(overrides, "status", assigns.filter_status))

    URI.encode_query(params)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> max(n, 1)
      :error -> default
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp bulk_flash_kind(0), do: :info
  defp bulk_flash_kind(_), do: :error

  defp bulk_message(ok_count, 0, label),
    do:
      ngettext("%{count} comment %{action}", "%{count} comments %{action}", ok_count,
        count: ok_count,
        action: label
      )

  defp bulk_message(0, err_count, label),
    do:
      ngettext(
        "%{count} comment could not be %{action}",
        "%{count} comments could not be %{action}",
        err_count,
        count: err_count,
        action: label
      )

  defp bulk_message(ok_count, err_count, label),
    do:
      gettext("%{ok} %{action}, %{failed} failed",
        ok: ok_count,
        action: label,
        failed: err_count
      )

  defp check_authorization(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "comments") do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp resource_info(resource_context, comment) do
    Map.get(resource_context, {comment.resource_type, comment.resource_uuid})
  end

  # Final navigable URL for a resolved resource: prefixes phoenix_kit paths and
  # appends the annotation deep-link param for file comments.
  defp resource_url(comment, %{path: path} = info) do
    base = if info[:prefixed], do: Routes.path(path), else: path
    link_with_annotation(base, comment)
  end

  # The resource shown as a compact clickable chip — a thumbnail for image
  # files (else the type badge) + the truncated title. Shared by the desktop
  # table cell and the mobile card view.
  attr(:comment, :map, required: true)
  attr(:resource_context, :map, required: true)
  attr(:class, :string, default: "")

  defp resource_chip(assigns) do
    assigns = assign(assigns, :info, resource_info(assigns.resource_context, assigns.comment))

    ~H"""
    <%= if @info do %>
      <%!-- Prefixed paths are phoenix_kit LiveView routes, so SPA-navigate.
           Non-prefixed paths come from host-configured templates and may point
           at a plain controller page or an external URL — use a real href there,
           since live navigation only works between LiveViews in the session. --%>
      <.link
        :if={@info[:prefixed]}
        navigate={resource_url(@comment, @info)}
        class={[chip_class(), @class]}
        title={@info[:full_title] || @info.title}
      >
        <.resource_chip_body comment={@comment} info={@info} />
      </.link>
      <.link
        :if={!@info[:prefixed]}
        href={resource_url(@comment, @info)}
        class={[chip_class(), @class]}
        title={@info[:full_title] || @info.title}
      >
        <.resource_chip_body comment={@comment} info={@info} />
      </.link>
    <% else %>
      <%!-- No handler and no path template for this resource_type — render a
           neutral, intentional-looking chip (humanized type + short uuid)
           rather than a bare uuid. Hosts can make it clickable without code by
           adding a path template in Settings → Comments → Resource Paths. --%>
      <div
        class={[
          "inline-flex items-center gap-1.5 max-w-[200px] py-0.5 px-2.5 rounded-full bg-base-200 align-middle",
          @class
        ]}
        title={"#{humanize_resource_type(@comment.resource_type)}: #{@comment.resource_uuid}"}
      >
        <.icon name="hero-tag" class="w-3.5 h-3.5 text-base-content/40 shrink-0" />
        <span class="truncate text-xs text-base-content/70 min-w-0">
          {humanize_resource_type(@comment.resource_type)}
        </span>
        <span class="text-xs font-mono text-base-content/40 shrink-0">
          {String.slice(to_string(@comment.resource_uuid), 0..5)}
        </span>
      </div>
    <% end %>
    """
  end

  defp chip_class do
    "inline-flex items-center gap-1.5 max-w-[240px] py-0.5 pl-1 pr-2.5 rounded-full bg-base-200 hover:bg-base-300 transition-colors no-underline align-middle"
  end

  # The chip's inner content. The thumbnail is a CSS background rather than an
  # `<img onerror=…>`: inline JS is blocked by a strict `script-src` CSP (and
  # AGENTS.md mandates hooks register on `window.PhoenixKitHooks`), and a missing
  # background image simply falls back to the placeholder colour — no handler.
  attr(:comment, :map, required: true)
  attr(:info, :map, required: true)

  defp resource_chip_body(assigns) do
    ~H"""
    <span
      :if={@info[:thumb_url]}
      class="w-5 h-5 rounded-full bg-base-300 bg-cover bg-center shrink-0"
      style={"background-image: url('#{@info.thumb_url}')"}
    />
    <span :if={!@info[:thumb_url]} class="badge badge-ghost badge-xs shrink-0">
      {humanize_resource_type(@comment.resource_type)}
    </span>
    <span class="truncate text-sm min-w-0">{@info.title}</span>
    """
  end

  # "test_page" -> "Test page". Used for the no-handler fallback chip so an
  # unconfigured resource type reads as a label, not a raw key.
  # Enough for one clamped line, cut on a boundary so markdown syntax is not
  # sliced mid-token.
  @preview_chars 200

  defp preview_source(content) when is_binary(content) do
    if String.length(content) > @preview_chars do
      String.slice(content, 0, @preview_chars) <> "…"
    else
      content
    end
  end

  defp preview_source(content), do: content

  defp humanize_resource_type(type) when is_binary(type) and type != "" do
    # Per WORD. `String.capitalize/1` lowercases the whole string, so
    # "api_key" became "Api key" and "GitHubRepo" became "Githubrepo".
    type
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_resource_type(_), do: gettext("Resource")

  # Reply indicator with a clickable parent preview. Clicking filters the list
  # to the parent by searching its uuid — so the original comment shows on its
  # own (full content + its resource chip / shape deep-link).
  attr(:comment, :map, required: true)

  defp reply_indicator(assigns) do
    ~H"""
    <div
      :if={@comment.depth > 0}
      class="flex items-center gap-1 text-base-content/50 text-xs mb-0.5"
    >
      <.icon name="hero-arrow-uturn-right-mini" class="size-3 shrink-0" />
      <span class="shrink-0">{gettext("Reply")}</span>
      <.link
        :if={@comment.parent}
        patch={
          Routes.path("/admin/comments?#{URI.encode_query(%{"search" => @comment.parent.uuid})}")
        }
        class="truncate max-w-[240px] text-left hover:text-base-content hover:underline"
        title={gettext("Show the original comment")}
      >
        {gettext("— Re: %{snippet}", snippet: parent_snippet(@comment.parent))}
      </.link>
    </div>
    """
  end

  # A short preview of the parent comment for the "— Re: …" reply label.
  # Parents can be GIF/attachment-only, so `content` may be nil/blank — fall
  # back to a placeholder instead of crashing on `String.slice(nil, _)`.
  defp parent_snippet(%{content: content}) when is_binary(content) and content != "",
    do: String.slice(content, 0..39)

  defp parent_snippet(_parent), do: gettext("[no text]")

  # One-line clickable comment preview. When the comment is longer than the line
  # (multi-line or long), a "Read more" cue makes it obvious it's truncated;
  # clicking anywhere opens the full-comment modal. Shared by table + card.
  attr(:comment, :map, required: true)

  defp comment_content_preview(assigns) do
    ~H"""
    <div
      class="group flex items-center gap-2 cursor-pointer"
      role="button"
      tabindex="0"
      phx-click="view_comment"
      phx-keydown="view_comment"
      phx-key="Enter"
      phx-value-uuid={@comment.uuid}
      title={gettext("Click to read the full comment")}
    >
      <div class="min-w-0 flex-1">
        <%!-- Media-only comments (GIF / attachment, no text) would render an
             empty preview; show a placeholder so the row isn't invisible. --%>
        <span
          :if={blank_content?(@comment.content)}
          class="inline-flex items-center gap-1 text-sm italic text-base-content/50"
        >
          <.icon name={media_icon(@comment)} class="w-4 h-4 shrink-0" />
          {media_placeholder(@comment)}
        </span>
        <%!-- Truncated at the SOURCE. This parsed and sanitised every
             comment body in full, per row, only to clamp the result to one
             line with CSS — the whole render cost for a single line of
             output. --%>
        <.comment_markdown
          :if={not blank_content?(@comment.content)}
          content={preview_source(@comment.content)}
          compact
          class="text-sm line-clamp-1"
        />
      </div>
      <span
        :if={preview_truncated?(@comment.content)}
        class="shrink-0 inline-flex items-center gap-0.5 text-xs font-medium text-primary group-hover:underline"
      >
        {gettext("Read more")} <.icon name="hero-chevron-right-mini" class="w-3.5 h-3.5" />
      </span>
    </div>
    """
  end

  # Heuristic for "the one-line preview is truncated": multi-line content, or a
  # single line long enough to overflow the narrow content column.
  defp preview_truncated?(content) when is_binary(content) do
    trimmed = String.trim(content)
    String.contains?(trimmed, "\n") or String.length(trimmed) > 50
  end

  defp preview_truncated?(_content), do: false

  # Comments may carry only a GIF or attachment, leaving `content` blank (see
  # `Comment.do_validate_content_or_media/2`). These helpers let the preview and
  # modal surface the media instead of an empty body.
  defp blank_content?(content), do: String.trim(to_string(content)) == ""

  defp comment_gif_url(%{metadata: %{"giphy" => %{"url" => url}}})
       when is_binary(url) and url != "",
       do: url

  defp comment_gif_url(_comment), do: nil

  # `media` is only preloaded for the modal's single comment; list rows leave it
  # unloaded (an `Ecto.Association.NotLoaded`), which falls through to 0.
  defp attachment_count(%{media: media}) when is_list(media), do: length(media)
  defp attachment_count(_comment), do: 0

  defp media_placeholder(comment) do
    if comment_gif_url(comment), do: gettext("GIF"), else: gettext("Attachment")
  end

  defp media_icon(comment) do
    if comment_gif_url(comment), do: "hero-photo", else: "hero-paper-clip"
  end

  # Status-aware row-action menu. The offered actions depend on the comment's
  # status: a deleted comment can only be Restored (not approved/hidden/deleted
  # again); otherwise Approve (unless already published), Hide (unless already
  # hidden), and Delete. Shared by the table and card views (distinct ids).
  attr(:comment, :map, required: true)
  attr(:id, :string, required: true)

  defp comment_actions_menu(assigns) do
    ~H"""
    <.table_row_menu id={@id} label={gettext("Comment actions")}>
      <.table_row_menu_button
        :if={@comment.status not in ["published", "deleted"]}
        phx-click="approve"
        phx-disable-with={gettext("Approving…")}
        phx-value-uuid={@comment.uuid}
        icon="hero-check"
        label={gettext("Approve")}
        variant="success"
      />
      <.table_row_menu_button
        :if={@comment.status not in ["hidden", "deleted"]}
        phx-click="hide"
        phx-disable-with={gettext("Hiding…")}
        phx-value-uuid={@comment.uuid}
        icon="hero-eye-slash"
        label={gettext("Hide")}
        variant="warning"
      />
      <.table_row_menu_button
        :if={@comment.status == "deleted"}
        phx-click="restore"
        phx-disable-with={gettext("Restoring…")}
        phx-value-uuid={@comment.uuid}
        icon="hero-arrow-uturn-left"
        label={gettext("Restore")}
        variant="success"
      />
      <.table_row_menu_divider :if={@comment.status != "deleted"} />
      <.table_row_menu_button
        :if={@comment.status != "deleted"}
        phx-click="delete"
        phx-value-uuid={@comment.uuid}
        phx-disable-with={gettext("Deleting…")}
        data-confirm={gettext("Delete this comment?")}
        icon="hero-trash"
        label={gettext("Delete")}
        variant="error"
      />
    </.table_row_menu>
    """
  end

  # Appends `?annotation=<uuid>` to a file comment's resource link so the media
  # page can select the Etcher shape the comment is anchored to (annotation
  # comments carry the back-reference in `metadata["annotation_uuid"]`).
  defp link_with_annotation(url, %{resource_type: "file", metadata: metadata})
       when is_map(metadata) do
    # Cast, don't just check for a non-empty string. This metadata is
    # free-form JSONB the client sets at create time, and the result goes
    # into an href the ADMIN clicks — so `annotation_uuid=x&status=published`
    # (or a `#fragment`) would ride along as extra query params on the target
    # page. Only a real uuid can be appended.
    with uuid when is_binary(uuid) <- Map.get(metadata, "annotation_uuid"),
         {:ok, valid} <- Ecto.UUID.cast(uuid) do
      sep = if String.contains?(url, "?"), do: "&", else: "?"
      url <> sep <> "annotation=" <> valid
    else
      _ -> url
    end
  end

  defp link_with_annotation(url, _comment), do: url

  defp status_badge_class("published"), do: "badge badge-success badge-sm"
  defp status_badge_class("pending"), do: "badge badge-warning badge-sm"
  defp status_badge_class("hidden"), do: "badge badge-info badge-sm"
  defp status_badge_class("deleted"), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm"

  # Literal `gettext/1` per clause, because the extractor only sees literals —
  # the msgids already exist and are already translated, since the stat tiles
  # and the filter dropdown on this very page use them. The badge printed the
  # raw DB enum instead, so a Russian admin saw the filter say
  # "Опубликовано" and the badge next to it say "published".
  defp status_label("published"), do: gettext("Published")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("hidden"), do: gettext("Hidden")
  defp status_label("deleted"), do: gettext("Deleted")
  defp status_label(other), do: other

  # The core card renders a `card_fields` entry's `value` as safe HTML, so the
  # grid view can show the same status badge as the table column instead of a
  # bare string. `status` is a fixed enum, but escape the label defensively.
  defp status_badge_value(status) do
    status = to_string(status)

    text =
      status |> status_label() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    Phoenix.HTML.raw(~s(<span class="#{status_badge_class(status)}">#{text}</span>))
  end
end
