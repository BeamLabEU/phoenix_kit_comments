defmodule PhoenixKitComments.Web.Index do
  @moduledoc """
  LiveView for comment moderation admin page.

  Provides cross-resource comment management with filtering, search,
  pagination, and bulk actions.

  ## Route

  Mounted at `{prefix}/admin/comments`.
  """

  use PhoenixKitWeb, :live_view

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
        |> assign(:page_title, "Comments")
        |> assign(:project_title, "")
        |> assign(:comments, [])
        |> assign(:total, 0)
        |> assign(:total_pages, 1)
        |> assign(:resource_context, %{})
        |> assign(:stats, empty_stats())
        |> assign(:selected_uuids, [])
        |> assign(:resource_types, [])
        |> assign_filter_defaults()
        |> maybe_load_dashboard_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Comments module is not enabled")
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

  @impl true
  def handle_event("approve", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.approve_comment(comment)

      {:noreply,
       socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment approved")}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Not authorized")}
      nil -> {:noreply, put_flash(socket, :error, "Comment not found")}
    end
  end

  @impl true
  def handle_event("hide", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.hide_comment(comment)

      {:noreply,
       socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment hidden")}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Not authorized")}
      nil -> {:noreply, put_flash(socket, :error, "Comment not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with :ok <- check_authorization(socket),
         %Comment{} = comment <- PhoenixKitComments.get_comment(uuid) do
      PhoenixKitComments.delete_comment(comment)

      {:noreply,
       socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment deleted")}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Not authorized")}
      nil -> {:noreply, put_flash(socket, :error, "Comment not found")}
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
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        do_bulk_action(action, socket)
    end
  end

  defp do_bulk_action(action, socket) do
    uuids = socket.assigns.selected_uuids

    if uuids == [] do
      {:noreply, put_flash(socket, :error, "No comments selected")}
    else
      case action do
        "approve" ->
          PhoenixKitComments.bulk_update_status(uuids, "published")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments approved")}

        "hide" ->
          PhoenixKitComments.bulk_update_status(uuids, "hidden")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments hidden")}

        "delete" ->
          PhoenixKitComments.bulk_update_status(uuids, "deleted")

          {:noreply,
           socket
           |> assign(:selected_uuids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments deleted")}

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

  defp status_badge_class("published"), do: "badge badge-success badge-sm"
  defp status_badge_class("pending"), do: "badge badge-warning badge-sm"
  defp status_badge_class("hidden"), do: "badge badge-info badge-sm"
  defp status_badge_class("deleted"), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm"
end
