defmodule PhoenixKitComments.Web.Index do
  @moduledoc """
  LiveView for comment moderation admin page.

  Provides cross-resource comment management with filtering, search,
  pagination, and bulk actions.

  ## Route

  Mounted at `{prefix}/admin/comments`.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitComments.Web.Markdown, only: [comment_markdown: 1, comment_markdown_styles: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitComments
  alias PhoenixKitComments.Comment

  @impl true
  def mount(_params, _session, socket) do
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
        |> assign(:selected_uuids, [])
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
    {:noreply,
     assign(socket, :viewing_comment, PhoenixKitComments.get_comment(uuid, preload: [:user]))}
  end

  @impl true
  def handle_event("close_comment", _params, socket) do
    {:noreply, assign(socket, :viewing_comment, nil)}
  end

  @impl true
  def handle_event("approve", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.approve_comment(comment)

      {:noreply,
       socket
       |> load_comments()
       |> reload_stats()
       |> put_flash(:info, gettext("Comment approved"))}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      nil -> {:noreply, put_flash(socket, :error, gettext("Comment not found"))}
    end
  end

  @impl true
  def handle_event("hide", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.hide_comment(comment)

      {:noreply,
       socket
       |> load_comments()
       |> reload_stats()
       |> put_flash(:info, gettext("Comment hidden"))}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      nil -> {:noreply, put_flash(socket, :error, gettext("Comment not found"))}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.delete_comment(comment)

      {:noreply,
       socket
       |> load_comments()
       |> reload_stats()
       |> put_flash(:info, gettext("Comment deleted"))}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      nil -> {:noreply, put_flash(socket, :error, gettext("Comment not found"))}
    end
  end

  # Revert a soft-deletion — brings the comment back as published.
  @impl true
  def handle_event("restore", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.approve_comment(comment)

      {:noreply,
       socket
       |> load_comments()
       |> reload_stats()
       |> put_flash(:info, gettext("Comment restored"))}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      nil -> {:noreply, put_flash(socket, :error, gettext("Comment not found"))}
    end
  end

  @impl true
  def handle_event("toggle_select", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.selected_uuids

    selected =
      if uuid in selected,
        do: List.delete(selected, uuid),
        else: [uuid | selected]

    {:noreply, assign(socket, :selected_uuids, selected)}
  end

  @impl true
  def handle_event("bulk_action", %{"action" => action}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      :ok ->
        do_bulk_action(action, socket)
    end
  end

  defp do_bulk_action(action, socket) do
    uuids = socket.assigns.selected_uuids

    if uuids == [] do
      {:noreply, put_flash(socket, :error, gettext("No comments selected"))}
    else
      case action do
        "approve" ->
          PhoenixKitComments.bulk_update_status(uuids, "published")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, gettext("Comments approved"))}

        "hide" ->
          PhoenixKitComments.bulk_update_status(uuids, "hidden")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, gettext("Comments hidden"))}

        "delete" ->
          PhoenixKitComments.bulk_update_status(uuids, "deleted")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, gettext("Comments deleted"))}

        _ ->
          {:noreply, socket}
      end
    end
  end

  ## --- Private ---

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
      <.link
        navigate={resource_url(@comment, @info)}
        class={[
          "inline-flex items-center gap-1.5 max-w-[240px] py-0.5 pl-1 pr-2.5 rounded-full bg-base-200 hover:bg-base-300 transition-colors no-underline align-middle",
          @class
        ]}
        title={@info[:full_title] || @info.title}
      >
        <img
          :if={@info[:thumb_url]}
          src={@info.thumb_url}
          alt=""
          class="w-5 h-5 rounded-full object-cover bg-base-300 shrink-0"
          onerror="this.style.display='none'"
        />
        <span :if={!@info[:thumb_url]} class="badge badge-ghost badge-xs shrink-0">
          {@comment.resource_type}
        </span>
        <span class="truncate text-sm min-w-0">{@info.title}</span>
      </.link>
    <% else %>
      <div
        class={[
          "inline-flex items-center gap-1.5 max-w-[200px] py-0.5 px-2.5 rounded-full bg-base-200 align-middle",
          @class
        ]}
        title={to_string(@comment.resource_uuid)}
      >
        <span class="badge badge-ghost badge-xs shrink-0">{@comment.resource_type}</span>
        <span class="truncate text-xs font-mono text-base-content/50 min-w-0">
          {String.slice(to_string(@comment.resource_uuid), 0..7)}
        </span>
      </div>
    <% end %>
    """
  end

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
      phx-click="view_comment"
      phx-value-uuid={@comment.uuid}
      title={gettext("Click to read the full comment")}
    >
      <div class="min-w-0 flex-1">
        <.comment_markdown content={@comment.content} compact class="text-sm line-clamp-1" />
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
        phx-value-uuid={@comment.uuid}
        icon="hero-check"
        label={gettext("Approve")}
        variant="success"
      />
      <.table_row_menu_button
        :if={@comment.status not in ["hidden", "deleted"]}
        phx-click="hide"
        phx-value-uuid={@comment.uuid}
        icon="hero-eye-slash"
        label={gettext("Hide")}
        variant="warning"
      />
      <.table_row_menu_button
        :if={@comment.status == "deleted"}
        phx-click="restore"
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
    case Map.get(metadata, "annotation_uuid") do
      uuid when is_binary(uuid) and uuid != "" ->
        sep = if String.contains?(url, "?"), do: "&", else: "?"
        url <> sep <> "annotation=" <> uuid

      _ ->
        url
    end
  end

  defp link_with_annotation(url, _comment), do: url

  defp status_badge_class("published"), do: "badge badge-success badge-sm"
  defp status_badge_class("pending"), do: "badge badge-warning badge-sm"
  defp status_badge_class("hidden"), do: "badge badge-info badge-sm"
  defp status_badge_class("deleted"), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm"
end
