defmodule PhoenixKitComments.Web.Settings do
  @moduledoc """
  LiveView for Comments module settings management.

  Manages:
  - `comments_enabled` — the module switch (written only when changed here)
  - `comments_rich_text` — Leaf editor in the composer
  - `comments_moderation` — new comments start `pending`
  - `comments_max_depth` (1–50), `comments_max_length` (100–100,000)
  - `comments_giphy_enabled`, `comments_giphy_api_key`, `comments_giphy_rating`
    (`g`/`pg`/`pg-13`/`r`)
  - `comments_attachments_enabled`, `comments_max_attachments` (1–10),
    `comments_attachment_max_size_mb` (1–500, clamped again at read time by
    the global storage cap)
  - core's `comment_resource_paths` — the resource link templates

  Every write carries the actor and `source: "settings"`, so it lands in
  core's settings history under the person who made it.

  ## Route

  Mounted at `{prefix}/admin/settings/comments`.
  """

  use PhoenixKitWeb, :live_view
  # Rebind gettext macros to the comments module's own catalogs (priv/gettext).
  use Gettext, backend: PhoenixKitComments.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  require Logger

  @impl true
  # Gated on mount, not just on save. Every write here checked, while the
  # page itself rendered `@comments_giphy_api_key` into a form value — masked
  # by `type="password"`, which is not a security control — for any admin
  # without the comments permission.
  def mount(_params, _session, socket) do
    case check_authorization(socket) do
      :ok ->
        do_mount(socket)

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not have access to comments settings."))
         |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp do_mount(socket) do
    socket =
      socket
      # Trail: Admin Panel / Settings / Comments — matches the sidebar label.
      |> assign(:page_title, gettext("Comments"))
      |> assign(:page_subtitle, gettext("Configure the standalone comments module"))
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, "")
      |> assign(:editing_resource_type, nil)
      |> assign(:editing_path_value, "")
      |> assign(:editing_title_value, "")
      |> assign(:draft_paths, %{})
      |> assign(:draft_titles, %{})
      |> assign(:active_tab, "general")
      |> assign_settings_defaults()

    socket =
      if connected?(socket) do
        socket
        |> assign(:project_title, Settings.get_project_title())
        |> load_settings()
      else
        socket
      end

    {:ok, socket}
  end

  @tabs ~w(general moderation limits giphy attachments links)

  @impl true
  def handle_event("switch_settings_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_settings_tab", _params, socket), do: {:noreply, socket}

  def handle_event("save", params, socket) do
    authorized(socket, fn -> do_save_settings(params, socket) end)
  end

  def handle_event("add_resource_path", %{"resource_path" => params}, socket)
      when is_map(params) do
    authorized(socket, fn -> do_add_resource_path(socket, params) end)
  end

  def handle_event("remove_resource_path", %{"type" => resource_type}, socket)
      when is_binary(resource_type) do
    authorized(socket, fn -> do_remove_resource_path(socket, resource_type) end)
  end

  def handle_event("edit_resource_path", %{"type" => resource_type}, socket)
      when is_binary(resource_type) do
    config = Map.get(socket.assigns.resource_paths, resource_type, %{})

    {:noreply,
     socket
     |> assign(:editing_resource_type, resource_type)
     |> assign(:editing_path_value, extract_path(config))
     |> assign(:editing_title_value, extract_title(config))}
  end

  def handle_event("cancel_edit_resource_path", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_resource_type, nil)
     |> assign(:editing_path_value, "")
     |> assign(:editing_title_value, "")}
  end

  def handle_event("live_edit_path", %{"resource_path" => params}, socket) when is_map(params) do
    {:noreply,
     socket
     |> assign(
       :editing_path_value,
       string_value(params, "path_template", socket.assigns.editing_path_value)
     )
     |> assign(
       :editing_title_value,
       string_value(params, "title_template", socket.assigns.editing_title_value)
     )}
  end

  def handle_event("live_draft_path", %{"resource_path" => params}, socket) when is_map(params) do
    resource_type = string_value(params, "resource_type", "")

    draft_paths =
      Map.put(
        socket.assigns.draft_paths,
        resource_type,
        string_value(params, "path_template", "")
      )

    draft_titles =
      Map.put(
        socket.assigns.draft_titles,
        resource_type,
        string_value(params, "title_template", "")
      )

    {:noreply,
     socket
     |> assign(:draft_paths, draft_paths)
     |> assign(:draft_titles, draft_titles)}
  end

  # Saving with no edit open — a replayed or hand-made event — wrote the
  # template under a `nil` key (stored as "nil") and flashed `Updated path
  # for ""`. There is nothing to save.
  def handle_event("save_resource_path", %{"resource_path" => params}, socket)
      when is_map(params) and is_binary(socket.assigns.editing_resource_type) do
    authorized(socket, fn -> do_save_resource_path(socket, params) end)
  end

  def handle_event("reset_defaults", _params, socket) do
    authorized(socket, fn -> do_reset_defaults(socket) end)
  end

  # Any other shape of a known event (a missing key, a map where a string
  # belongs) is ignored rather than left to match no clause, which took the
  # page down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## --- Private ---

  @allowed_settings ~w(
    comments_enabled
    comments_moderation
    comments_rich_text
    comments_max_depth
    comments_max_length
    comments_giphy_enabled
    comments_giphy_api_key
    comments_giphy_rating
    comments_attachments_enabled
    comments_max_attachments
    comments_attachment_max_size_mb
  )

  @numeric_settings %{
    "comments_max_depth" => {1, 50, "10"},
    "comments_max_length" => {100, 100_000, "10000"},
    "comments_max_attachments" => {1, 10, "4"},
    "comments_attachment_max_size_mb" => {1, 500, "20"}
  }

  @boolean_settings ~w(
    comments_enabled
    comments_moderation
    comments_rich_text
    comments_giphy_enabled
    comments_attachments_enabled
  )

  @giphy_ratings ~w(g pg pg-13 r)

  # What Reset puts back. Not the module switch: Reset turned comments OFF
  # (its default is "false") under a confirm that spoke of "moderation,
  # limits, Giphy and attachment options". Not the Giphy key either: it is
  # a credential, not an option with a default, and Reset erased it. Nor the
  # resource path templates — those are configured data, not settings.
  @reset_defaults %{
    "comments_moderation" => "false",
    "comments_rich_text" => "true",
    "comments_max_depth" => "10",
    "comments_max_length" => "10000",
    "comments_giphy_enabled" => "false",
    "comments_giphy_rating" => "g",
    "comments_attachments_enabled" => "false",
    "comments_max_attachments" => "4",
    "comments_attachment_max_size_mb" => "20"
  }

  # The rest of the form in ONE transaction (`update_settings_batch/2`): the
  # old loop was eleven, so a failure part-way left some keys saved under
  # "Failed to save some settings" with no way to tell which.
  defp do_save_settings(params, socket) do
    {switch, settings} =
      params
      |> Map.get("settings", %{})
      |> sanitize_settings()
      |> drop_blank_new_settings()
      |> Map.pop("comments_enabled")

    with {:ok, _} <- Settings.update_settings_batch(settings, history_opts(socket)),
         :ok <- maybe_switch_module(socket, switch) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Settings saved successfully"))
       |> load_settings()}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to save some settings"))
         |> load_settings()}
    end
  rescue
    e ->
      # The struct name only. This writes comments_giphy_api_key among other
      # settings, and Ecto/DBConnection exceptions in this class
      # (ChangeError, EncodeError, CastError) interpolate the offending
      # VALUE into their message — so logging Exception.message/1 here could
      # put the API key in plaintext in the log. Same stance the Giphy call
      # site already takes.
      Logger.error("Comment settings save failed: #{inspect(e.__struct__)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  # Core refuses to INSERT a setting with an empty value ("must provide
  # either value or value_json"). The Giphy key field is empty on every site
  # that has never stored one, so the old loop failed that key on every save
  # and flashed "Failed to save some settings" over a save that had worked;
  # in one transaction it would fail the whole form. An empty value for a
  # key with no row yet has nothing to clear.
  defp drop_blank_new_settings(settings) do
    Map.reject(settings, fn {key, value} -> value == "" and Settings.get_setting(key) == nil end)
  end

  # The module switch, written only when it differs from what this page
  # LOADED. Every save re-posts the toggle, so saving the limits on a page
  # opened before the Owner switched comments off turned them back on.
  #
  # Written like `enable_system/0` / `disable_system/0` (with the module
  # key), plus the actor those callbacks cannot take, and announced the way
  # core's Modules page announces a toggle, so other sessions' sidebars and
  # open pages hear of it.
  defp maybe_switch_module(socket, value) when value in ["true", "false"] do
    if value == socket.assigns.comments_enabled do
      :ok
    else
      enabled? = value == "true"

      case Settings.update_boolean_setting_with_module(
             "comments_enabled",
             enabled?,
             "comments",
             history_opts(socket)
           ) do
        {:ok, _} ->
          announce_module_switch(enabled?)
          :ok

        error ->
          error
      end
    end
  end

  defp maybe_switch_module(_socket, _value), do: :ok

  # Best-effort, like every broadcast here: the write has happened.
  defp announce_module_switch(enabled?) do
    if enabled?,
      do: Events.broadcast_module_enabled("comments"),
      else: Events.broadcast_module_disabled("comments")
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp do_reset_defaults(socket) do
    case Settings.update_settings_batch(@reset_defaults, history_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings reset to defaults"))
         |> load_settings()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
    end
  rescue
    e ->
      Logger.error("Comment settings reset failed: #{inspect(e.__struct__)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  # Who changed it, for core's settings history — the same options core's
  # own settings pages pass. Without them every entry read "system".
  defp history_opts(socket), do: [actor_uuid: Actor.uuid(socket), source: "settings"]

  # Only the keys this page owns, only string values (a crafted
  # `settings[comments_max_depth][x]=1` reached `to_string/1` on a map and
  # raised), numbers clamped, booleans and the Giphy rating from their
  # allowed values — anything else is dropped rather than stored.
  defp sanitize_settings(settings) when is_map(settings) do
    settings
    |> Map.take(@allowed_settings)
    |> Enum.flat_map(fn {key, value} -> sanitize_setting(key, value) end)
    |> Map.new()
  end

  defp sanitize_settings(_), do: %{}

  defp sanitize_setting(_key, value) when not is_binary(value), do: []

  defp sanitize_setting(key, value) when key in @boolean_settings do
    if value in ["true", "false"], do: [{key, value}], else: []
  end

  defp sanitize_setting("comments_giphy_rating", value) do
    if value in @giphy_ratings, do: [{"comments_giphy_rating", value}], else: []
  end

  defp sanitize_setting(key, value), do: [{key, clamp_numeric(key, value)}]

  defp clamp_numeric(key, value) do
    case Map.get(@numeric_settings, key) do
      nil ->
        value

      {min, max, default} ->
        case Integer.parse(value) do
          {n, _} -> n |> Kernel.max(min) |> Kernel.min(max) |> to_string()
          :error -> default
        end
    end
  end

  defp do_add_resource_path(socket, params) do
    resource_type = trimmed(params, "resource_type")
    path_template = trimmed(params, "path_template")
    title_template = trimmed(params, "title_template")

    save_resource_config(socket, resource_type, path_template, title_template, fn socket ->
      socket
      |> assign(:draft_paths, Map.delete(socket.assigns.draft_paths, resource_type))
      |> assign(:draft_titles, Map.delete(socket.assigns.draft_titles, resource_type))
      |> put_flash(:info, gettext("Added path for \"%{type}\"", type: resource_type))
    end)
  end

  defp do_save_resource_path(socket, params) do
    resource_type = socket.assigns.editing_resource_type
    path_template = trimmed(params, "path_template")
    title_template = trimmed(params, "title_template")

    save_resource_config(socket, resource_type, path_template, title_template, fn socket ->
      socket
      |> assign(:editing_resource_type, nil)
      |> assign(:editing_path_value, "")
      |> assign(:editing_title_value, "")
      |> put_flash(:info, gettext("Updated path for \"%{type}\"", type: resource_type))
    end)
  end

  defp save_resource_config(socket, resource_type, path_template, title_template, on_success) do
    with :ok <- validate_resource_path(resource_type, path_template),
         {:ok, _} <-
           change_templates(
             socket,
             &Map.put(&1, resource_type, build_config(path_template, title_template))
           ) do
      {:noreply,
       socket
       |> on_success.()
       |> load_settings()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Something went wrong. Please try again."))
         |> load_settings()}
    end
  end

  defp do_remove_resource_path(socket, resource_type) do
    case change_templates(socket, &Map.delete(&1, resource_type)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Removed path for \"%{type}\"", type: resource_type))
         |> load_settings()}

      _error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Something went wrong. Please try again."))
         |> load_settings()}
    end
  end

  # One change to the templates as they are NOW. Writing back the page's
  # copy (taken at mount or the last action) as the whole map deleted every
  # template another admin — or another tab — had added since. Written with
  # the actor, which `PhoenixKitComments.update_resource_path_templates/1`
  # (core's `ResourceLinks`) cannot pass on; the key is core's.
  @templates_key "comment_resource_paths"

  defp change_templates(socket, fun) do
    PhoenixKitComments.get_resource_path_templates()
    |> fun.()
    |> then(&Settings.update_json_setting(@templates_key, &1, history_opts(socket)))
  end

  defp build_config(path_template, ""), do: %{"path" => path_template}

  defp build_config(path_template, title_template),
    do: %{"path" => path_template, "title" => title_template}

  defp validate_resource_path("", _), do: {:error, gettext("Resource type is required")}
  defp validate_resource_path(_, ""), do: {:error, gettext("Path template is required")}

  # The template becomes an href an admin clicks on the moderation page (and
  # in core's Activity feed). `"://"` was the only guard, so
  # `//evil.example/:uuid` — a protocol-relative URL — passed, and on a
  # root-prefixed site so did `:prefixjavascript:alert(1)//:uuid`, which
  # `<.link href>` then refused to render, taking the moderation page down
  # whenever a comment of that type was listed. Checked with `:prefix` as
  # the empty string, the root-prefix case core substitutes, which is the
  # strictest: the result must be a path on this site
  # (`Routes.local_path?/1`: no `//`, no `/\`, no control characters).
  # `:uuid` and `:metadata.*` values are URL-encoded by core, so they
  # cannot add a scheme or a host.
  defp validate_resource_path(_resource_type, path_template) do
    cond do
      not (String.starts_with?(path_template, "/") or
               String.starts_with?(path_template, ":prefix")) ->
        {:error, gettext("Path template must start with / or :prefix")}

      String.contains?(path_template, "://") or
          not Routes.local_path?(String.replace(path_template, ":prefix", "")) ->
        {:error, gettext("Path template must be a relative path")}

      not (String.contains?(path_template, ":uuid") or
               String.contains?(path_template, ":metadata.")) ->
        {:error, gettext("Path template must contain :uuid or :metadata.KEY placeholders")}

      true ->
        :ok
    end
  end

  defp assign_settings_defaults(socket) do
    socket
    |> assign(:comments_enabled, "false")
    |> assign(:comments_moderation, "false")
    |> assign(:comments_rich_text, "true")
    |> assign(:comments_max_depth, "10")
    |> assign(:comments_max_length, "10000")
    |> assign(:comments_giphy_enabled, "false")
    |> assign(:comments_giphy_api_key, "")
    |> assign(:comments_giphy_rating, "g")
    |> assign(:comments_attachments_enabled, "false")
    |> assign(:comments_max_attachments, "4")
    |> assign(:comments_attachment_max_size_mb, "20")
    |> assign(:resource_paths, %{})
    |> assign(:counts_by_type, %{})
    |> assign(:unconfigured_types, [])
    |> assign(:metadata_keys_by_type, %{})
  end

  defp load_settings(socket) do
    resource_paths = PhoenixKitComments.get_resource_path_templates()
    counts_by_type = PhoenixKitComments.count_comments_by_type()

    linked_types = MapSet.new(Map.keys(resource_paths) ++ handler_types())

    unconfigured_types =
      counts_by_type
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(linked_types, &1))
      |> Enum.sort()

    metadata_keys_by_type = PhoenixKitComments.list_metadata_keys_by_type()

    socket
    |> assign(:comments_enabled, Settings.get_setting("comments_enabled", "false"))
    |> assign(:comments_moderation, Settings.get_setting("comments_moderation", "false"))
    |> assign(:comments_rich_text, Settings.get_setting("comments_rich_text", "true"))
    |> assign(:comments_max_depth, Settings.get_setting("comments_max_depth", "10"))
    |> assign(:comments_max_length, Settings.get_setting("comments_max_length", "10000"))
    |> assign(:comments_giphy_enabled, Settings.get_setting("comments_giphy_enabled", "false"))
    |> assign(:comments_giphy_api_key, Settings.get_setting("comments_giphy_api_key", ""))
    |> assign(:comments_giphy_rating, Settings.get_setting("comments_giphy_rating", "g"))
    |> assign(
      :comments_attachments_enabled,
      Settings.get_setting("comments_attachments_enabled", "false")
    )
    |> assign(:comments_max_attachments, Settings.get_setting("comments_max_attachments", "4"))
    |> assign(
      :comments_attachment_max_size_mb,
      Settings.get_setting("comments_attachment_max_size_mb", "20")
    )
    |> assign(:resource_paths, resource_paths)
    |> assign(:counts_by_type, counts_by_type)
    |> assign(:unconfigured_types, unconfigured_types)
    |> assign(:metadata_keys_by_type, metadata_keys_by_type)
  end

  # Types a resource handler links already. Core asks the handler before any
  # template, so listing them under "Resource types without link patterns"
  # (core's `post`, `file`, `user`, every module's own) nudged the admin to
  # add a template that would never be used.
  defp handler_types do
    for {type, handler} <- PhoenixKit.ResourceLinks.handlers(),
        is_atom(handler),
        Code.ensure_loaded?(handler),
        function_exported?(handler, :resolve_comment_resources, 1),
        do: type
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp trimmed(params, key), do: params |> string_value(key, "") |> String.trim()

  defp string_value(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp extract_path(config) when is_binary(config), do: config
  defp extract_path(%{"path" => path}), do: path
  defp extract_path(_), do: ""

  defp extract_title(config) when is_binary(config), do: ""
  defp extract_title(%{"title" => title}) when is_binary(title), do: title
  defp extract_title(_), do: ""

  # `comments.settings`, not the base key: the base key now means "moderate
  # comments on records you manage", which is no reason to hold the Giphy
  # key or switch the module off. See `PhoenixKitComments.can_change_settings?/1`
  # for why this is not `Scope.can?/2`.
  defp check_authorization(socket) do
    if PhoenixKitComments.can_change_settings?(socket.assigns[:phoenix_kit_current_scope]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorized(socket, fun) do
    case check_authorization(socket) do
      :ok -> fun.()
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  @doc """
  Lightweight in-card section heading (icon + title + rule). Local copy of
  core's `Core.FormSection.section_header/1` under a distinct name, so this
  package renders identically without requiring a core release that exports
  it (and won't conflict with the core import once it does).
  """
  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)
  attr(:class, :string, default: nil)

  def settings_section_header(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 pt-4 first:pt-0", @class]}>
      <.icon name={@icon} class="w-4 h-4 text-primary/70" />
      <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        {@title}
      </h3>
      <div class="flex-1 border-t border-base-300 ml-2"></div>
    </div>
    """
  end
end
