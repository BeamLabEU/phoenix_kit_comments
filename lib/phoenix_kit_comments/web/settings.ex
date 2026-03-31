defmodule PhoenixKitComments.Web.Settings do
  @moduledoc """
  LiveView for Comments module settings management.

  Manages:
  - `comments_enabled` toggle
  - `comments_moderation` toggle
  - `comments_max_depth` input
  - `comments_max_length` input

  ## Route

  Mounted at `{prefix}/admin/settings/comments`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, "Comments Settings")
      |> assign(:project_title, project_title)
      |> assign(:saving, false)
      |> assign(:editing_resource_type, nil)
      |> assign(:editing_path_value, "")
      |> assign(:editing_title_value, "")
      |> assign(:draft_paths, %{})
      |> assign(:draft_titles, %{})
      |> load_settings()

    {:ok, socket}
  end

  @impl true
  def handle_event("save", params, socket) do
    # Verify authorization before saving
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        do_save_settings(params, socket)
    end
  end

  @impl true
  def handle_event("add_resource_path", %{"resource_path" => params}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        do_add_resource_path(socket, params)
    end
  end

  @impl true
  def handle_event("remove_resource_path", %{"type" => resource_type}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        templates = Map.delete(socket.assigns.resource_paths, resource_type)
        PhoenixKitComments.update_resource_path_templates(templates)

        {:noreply,
         socket
         |> put_flash(:info, "Removed path for \"#{resource_type}\"")
         |> load_settings()}
    end
  end

  @impl true
  def handle_event("edit_resource_path", %{"type" => resource_type}, socket) do
    config = Map.get(socket.assigns.resource_paths, resource_type, %{})

    {:noreply,
     socket
     |> assign(:editing_resource_type, resource_type)
     |> assign(:editing_path_value, extract_path(config))
     |> assign(:editing_title_value, extract_title(config))}
  end

  @impl true
  def handle_event("cancel_edit_resource_path", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_resource_type, nil)
     |> assign(:editing_path_value, "")
     |> assign(:editing_title_value, "")}
  end

  @impl true
  def handle_event("live_edit_path", %{"resource_path" => params}, socket) do
    {:noreply,
     socket
     |> assign(:editing_path_value, params["path_template"] || socket.assigns.editing_path_value)
     |> assign(
       :editing_title_value,
       params["title_template"] || socket.assigns.editing_title_value
     )}
  end

  @impl true
  def handle_event("live_draft_path", %{"resource_path" => params}, socket) do
    resource_type = params["resource_type"] || ""
    path_value = params["path_template"] || ""
    title_value = params["title_template"] || ""
    draft_paths = Map.put(socket.assigns.draft_paths, resource_type, path_value)
    draft_titles = Map.put(socket.assigns.draft_titles, resource_type, title_value)

    {:noreply,
     socket
     |> assign(:draft_paths, draft_paths)
     |> assign(:draft_titles, draft_titles)}
  end

  @impl true
  def handle_event("save_resource_path", %{"resource_path" => params}, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        do_save_resource_path(socket, params)
    end
  end

  @impl true
  def handle_event("reset_defaults", _params, socket) do
    case check_authorization(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      :ok ->
        # Resource path templates are intentionally NOT reset here —
        # they are user-configured data, not settings with defaults.
        defaults = %{
          "comments_enabled" => "false",
          "comments_moderation" => "false",
          "comments_max_depth" => "10",
          "comments_max_length" => "10000"
        }

        Enum.each(defaults, fn {key, value} ->
          Settings.update_setting(key, value)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Settings reset to defaults")
         |> load_settings()}
    end
  end

  ## --- Private ---

  defp do_save_settings(params, socket) do
    socket = assign(socket, :saving, true)
    settings = Map.get(params, "settings", %{})

    try do
      results =
        Enum.map(settings, fn {key, value} ->
          Settings.update_setting(key, value)
        end)

      socket =
        if Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end) do
          socket
          |> put_flash(:info, "Settings saved successfully")
          |> load_settings()
        else
          put_flash(socket, :error, "Failed to save some settings")
        end

      {:noreply, assign(socket, :saving, false)}
    rescue
      e ->
        require Logger
        Logger.error("Comment settings save failed: #{Exception.message(e)}")

        {:noreply,
         assign(socket, :saving, false)
         |> put_flash(:error, "Something went wrong. Please try again.")}
    end
  end

  defp do_add_resource_path(socket, params) do
    resource_type = String.trim(params["resource_type"] || "")
    path_template = String.trim(params["path_template"] || "")
    title_template = String.trim(params["title_template"] || "")

    case validate_resource_path(resource_type, path_template) do
      :ok ->
        config = build_config(path_template, title_template)
        templates = Map.put(socket.assigns.resource_paths, resource_type, config)
        PhoenixKitComments.update_resource_path_templates(templates)

        {:noreply,
         socket
         |> put_flash(:info, "Added path for \"#{resource_type}\"")
         |> load_settings()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp do_save_resource_path(socket, params) do
    resource_type = socket.assigns.editing_resource_type
    path_template = String.trim(params["path_template"] || "")
    title_template = String.trim(params["title_template"] || "")

    case validate_resource_path(resource_type, path_template) do
      :ok ->
        config = build_config(path_template, title_template)
        templates = Map.put(socket.assigns.resource_paths, resource_type, config)
        PhoenixKitComments.update_resource_path_templates(templates)

        {:noreply,
         socket
         |> assign(:editing_resource_type, nil)
         |> assign(:editing_title_value, "")
         |> put_flash(:info, "Updated path for \"#{resource_type}\"")
         |> load_settings()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp build_config(path_template, ""), do: %{"path" => path_template}
  defp build_config(path_template, title_template),
    do: %{"path" => path_template, "title" => title_template}

  defp validate_resource_path("", _), do: {:error, "Resource type is required"}
  defp validate_resource_path(_, ""), do: {:error, "Path template is required"}

  defp validate_resource_path(_resource_type, path_template) do
    cond do
      not (String.starts_with?(path_template, "/") or
               String.starts_with?(path_template, ":prefix")) ->
        {:error, "Path template must start with / or :prefix"}

      String.contains?(path_template, "://") ->
        {:error, "Path template must be a relative path"}

      not (String.contains?(path_template, ":uuid") or
               String.contains?(path_template, ":metadata.")) ->
        {:error, "Path template must contain :uuid or :metadata.KEY placeholders"}

      true ->
        :ok
    end
  end

  defp load_settings(socket) do
    resource_paths = PhoenixKitComments.get_resource_path_templates()
    counts_by_type = PhoenixKitComments.count_comments_by_type()

    unconfigured_types =
      counts_by_type
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(resource_paths, &1))
      |> Enum.sort()

    metadata_keys_by_type = PhoenixKitComments.list_metadata_keys_by_type()

    socket
    |> assign(:comments_enabled, Settings.get_setting("comments_enabled", "false"))
    |> assign(:comments_moderation, Settings.get_setting("comments_moderation", "false"))
    |> assign(:comments_max_depth, Settings.get_setting("comments_max_depth", "10"))
    |> assign(:comments_max_length, Settings.get_setting("comments_max_length", "10000"))
    |> assign(:resource_paths, resource_paths)
    |> assign(:counts_by_type, counts_by_type)
    |> assign(:unconfigured_types, unconfigured_types)
    |> assign(:metadata_keys_by_type, metadata_keys_by_type)
  end

  def extract_path(config) when is_binary(config), do: config
  def extract_path(%{"path" => path}), do: path
  def extract_path(_), do: ""

  def extract_title(config) when is_binary(config), do: ""
  def extract_title(%{"title" => title}) when is_binary(title), do: title
  def extract_title(_), do: ""

  defp check_authorization(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "comments") do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
