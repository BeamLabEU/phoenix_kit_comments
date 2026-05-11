defmodule PhoenixKitComments.Web.CommentsComponent do
  @moduledoc """
  Reusable LiveComponent for displaying and managing comments on any resource.

  ## Usage

      <.live_component
        module={PhoenixKitComments.Web.CommentsComponent}
        id={"comments-\#{@post.uuid}"}
        resource_type="post"
        resource_uuid={@post.uuid}
        current_user={@current_user}
      />

  ## Required Attrs

  - `resource_type` - String identifying the resource type (e.g., "post")
  - `resource_uuid` - UUID of the resource
  - `current_user` - Current authenticated user struct
  - `id` - Unique component ID

  ## Optional Attrs

  - `enabled` - Whether comments are enabled (default: true)
  - `show_likes` - Show like/dislike buttons (default: false)
  - `title` - Section title (default: "Comments")

  ## Slots

  - `:form_extras` - Custom markup rendered inside the new-comment form. Use it to
    inject parent-project inputs whose names are `metadata[<key>]`; their values are
    merged into `comment.metadata` on submit. The `"giphy"` key is reserved for the
    built-in Giphy picker.

        <:form_extras>
          <input type="color" name="metadata[box_color]" value="#ff5555" />
        </:form_extras>

  ## Parent Notifications

  After create/delete, sends to the parent LiveView:

      {:comments_updated, %{resource_type: "post", resource_uuid: uuid, action: :created | :deleted}}
  """

  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Users.Roles

  @impl true
  def mount(socket) do
    max_size_mb = PhoenixKitComments.get_max_attachment_size_mb()
    max_entries = PhoenixKitComments.get_max_attachments()

    {:ok,
     socket
     |> assign(:comments, [])
     |> assign(:comment_count, 0)
     |> assign(:loaded?, false)
     |> assign(:reply_to, nil)
     |> assign(:new_comment, "")
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")
     |> assign(:giphy_open?, false)
     |> assign(:giphy_query, "")
     |> assign(:giphy_results, [])
     |> assign(:giphy_selected, nil)
     |> assign(:attach_menu_open?, false)
     |> assign(:recording_audio?, false)
     |> assign(:max_attachments, max_entries)
     |> assign(:max_attachment_size_mb, max_size_mb)
     |> allow_upload(:attachment,
       accept: ~w(
         image/*
         video/*
         audio/*
         .pdf .doc .docx .txt .md
         .zip .rar .7z
       ),
       max_entries: max_entries,
       max_file_size: max_size_mb * 1024 * 1024
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:enabled, fn -> true end)
      |> assign_new(:show_likes, fn -> false end)
      |> assign_new(:title, fn -> "Comments" end)
      |> assign_new(:form_extras, fn -> [] end)
      |> assign_new(:current_user, fn -> nil end)
      |> assign(:can_post?, assigns[:current_user] != nil)
      |> assign(:giphy_enabled?, PhoenixKitComments.giphy_enabled?())
      |> assign(:attachments_enabled?, PhoenixKitComments.attachments_enabled?())
      |> assign(:max_length, PhoenixKitComments.get_max_length())

    socket =
      if changed?(socket, :resource_uuid) or not socket.assigns.loaded? do
        socket |> load_comments() |> assign(:loaded?, true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("add_comment", _params, %{assigns: %{can_post?: false}} = socket) do
    {:noreply, put_flash(socket, :error, "Sign in to post a comment")}
  end

  def handle_event("add_comment", params, socket) do
    comment_text = Map.get(params, "comment", "")

    metadata_params =
      params
      |> Map.get("metadata", %{})
      |> Map.delete("giphy")

    metadata =
      case socket.assigns.giphy_selected do
        nil -> metadata_params
        gif -> Map.put(metadata_params, "giphy", gif)
      end

    base_attrs = %{
      content: comment_text,
      parent_uuid: socket.assigns.reply_to,
      metadata: metadata
    }

    entry_count = length(socket.assigns.uploads.attachment.entries)

    # Precheck before `consume_uploaded_entries` so depth / length /
    # cap / feature-flag failures don't burn the upload — the entries
    # stay staged and the user can fix the input and resubmit.
    case PhoenixKitComments.precheck_create(
           socket.assigns.resource_type,
           socket.assigns.resource_uuid,
           socket.assigns.current_user.uuid,
           base_attrs,
           entry_count
         ) do
      :ok ->
        do_create_comment(socket, base_attrs)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, create_error_message(reason))}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  def handle_event("audio_recording_started", _params, socket) do
    {:noreply, assign(socket, :recording_audio?, true)}
  end

  def handle_event("audio_recording_stopped", _params, socket) do
    {:noreply, assign(socket, :recording_audio?, false)}
  end

  def handle_event("audio_recording_error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:recording_audio?, false)
     |> put_flash(:error, message)}
  end

  @impl true
  def handle_event("update_comment_draft", %{"comment" => text}, socket) do
    {:noreply, assign(socket, :new_comment, text)}
  end

  def handle_event("update_comment_draft", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_new_comment", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_comment, "")
     |> assign(:giphy_selected, nil)
     |> assign(:giphy_open?, false)
     |> assign(:giphy_results, [])
     |> assign(:giphy_query, "")}
  end

  @impl true
  def handle_event("toggle_giphy_picker", _params, socket) do
    {:noreply, assign(socket, :giphy_open?, not socket.assigns.giphy_open?)}
  end

  @impl true
  def handle_event("close_giphy_picker", _params, socket) do
    {:noreply, assign(socket, :giphy_open?, false)}
  end

  def handle_event("toggle_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, not socket.assigns.attach_menu_open?)}
  end

  def handle_event("close_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, false)}
  end

  def handle_event("open_giphy_from_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:attach_menu_open?, false)
     |> assign(:giphy_open?, true)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("giphy_search", %{"value" => query}, socket) do
    case PhoenixKitComments.search_giphy(query) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:giphy_query, query)
         |> assign(:giphy_results, results)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:giphy_query, query)
         |> assign(:giphy_results, [])
         |> put_flash(:error, "Giphy search failed. Check the API key in settings.")}
    end
  end

  def handle_event("giphy_search", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_giphy", %{"id" => gif_id}, socket) do
    case Enum.find(socket.assigns.giphy_results, &(&1["id"] == gif_id)) do
      nil ->
        {:noreply, socket}

      gif ->
        {:noreply,
         socket
         |> assign(:giphy_selected, gif)
         |> assign(:giphy_open?, false)}
    end
  end

  @impl true
  def handle_event("remove_giphy", _params, socket) do
    {:noreply, assign(socket, :giphy_selected, nil)}
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:reply_to, comment_uuid)
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")}
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  @impl true
  def handle_event("edit_comment", %{"id" => comment_uuid}, socket) do
    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        if can_edit_comment?(socket.assigns.current_user, comment) do
          {:noreply,
           socket
           |> assign(:editing_uuid, comment_uuid)
           |> assign(:editing_content, comment.content)
           |> assign(:reply_to, nil)}
        else
          {:noreply, put_flash(socket, :error, "You don't have permission to edit this comment")}
        end
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")}
  end

  @impl true
  def handle_event("save_edit", %{"content" => content}, socket) do
    comment_uuid = socket.assigns.editing_uuid

    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        if comment.resource_type != socket.assigns.resource_type or
             comment.resource_uuid != socket.assigns.resource_uuid do
          {:noreply, put_flash(socket, :error, "Invalid comment for this resource")}
        else
          do_save_edit(socket, comment, content)
        end
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => comment_uuid}, socket) do
    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Comment not found")}

      comment ->
        do_delete_comment(socket, comment)
    end
  end

  defp do_create_comment(socket, base_attrs) do
    case consume_attachments(socket) do
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:ok, file_uuids} ->
        attrs = Map.put(base_attrs, :attachment_file_uuids, file_uuids)

        case PhoenixKitComments.create_comment(
               socket.assigns.resource_type,
               socket.assigns.resource_uuid,
               socket.assigns.current_user.uuid,
               attrs
             ) do
          {:ok, _comment} ->
            send(
              self(),
              {:comments_updated,
               %{
                 resource_type: socket.assigns.resource_type,
                 resource_uuid: socket.assigns.resource_uuid,
                 action: :created
               }}
            )

            {:noreply,
             socket
             |> assign(:new_comment, "")
             |> assign(:reply_to, nil)
             |> assign(:giphy_selected, nil)
             |> assign(:giphy_open?, false)
             |> assign(:giphy_results, [])
             |> assign(:giphy_query, "")
             |> assign(:recording_audio?, false)
             |> load_comments()
             |> put_flash(:info, "Comment added")}

          {:error, %Ecto.Changeset{} = changeset} ->
            message = first_error_message(changeset) || "Failed to add comment"
            {:noreply, put_flash(socket, :error, message)}

          {:error, reason} when is_atom(reason) ->
            {:noreply, put_flash(socket, :error, create_error_message(reason))}
        end
    end
  end

  defp create_error_message(:empty_comment), do: "Comment can't be empty"
  defp create_error_message(:attachments_disabled), do: "Attachments are disabled"

  defp create_error_message(:too_many_attachments),
    do: "Up to #{PhoenixKitComments.get_max_attachments()} attachments per comment"

  defp create_error_message(:max_depth_exceeded), do: "Reply nesting is too deep"
  defp create_error_message(:content_too_long), do: "Comment exceeds maximum length"
  defp create_error_message(:invalid_user_uuid), do: "Invalid user"
  defp create_error_message(:invalid_file_uuid), do: "Invalid file attachment"
  defp create_error_message(_), do: "Failed to add comment"

  defp do_delete_comment(socket, comment) do
    cond do
      # First verify the comment belongs to the current resource (IDOR protection)
      comment.resource_type != socket.assigns.resource_type or
          comment.resource_uuid != socket.assigns.resource_uuid ->
        {:noreply, socket |> put_flash(:error, "Invalid comment for this resource")}

      not can_delete_comment?(socket.assigns.current_user, comment) ->
        {:noreply,
         socket |> put_flash(:error, "You don't have permission to delete this comment")}

      true ->
        execute_delete(socket, comment)
    end
  end

  defp do_save_edit(socket, comment, content) do
    max_length = PhoenixKitComments.get_max_length()
    content = String.trim(content)

    cond do
      content == "" ->
        {:noreply, put_flash(socket, :error, "Comment cannot be empty")}

      String.length(content) > max_length ->
        {:noreply,
         put_flash(socket, :error, "Comment exceeds maximum length of #{max_length} characters")}

      not can_edit_comment?(socket.assigns.current_user, comment) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this comment")}

      true ->
        do_update_comment(socket, comment, content)
    end
  end

  defp do_update_comment(socket, comment, content) do
    case PhoenixKitComments.update_comment(comment, %{content: content}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_uuid, nil)
         |> assign(:editing_content, "")
         |> load_comments()
         |> put_flash(:info, "Comment updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update comment")}
    end
  end

  defp execute_delete(socket, comment) do
    case PhoenixKitComments.delete_comment(comment) do
      {:ok, _} ->
        send(
          self(),
          {:comments_updated,
           %{
             resource_type: socket.assigns.resource_type,
             resource_uuid: socket.assigns.resource_uuid,
             action: :deleted
           }}
        )

        {:noreply,
         socket
         |> load_comments()
         |> put_flash(:info, "Comment deleted")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Failed to delete comment")}
    end
  end

  defp consume_attachments(socket) do
    if Enum.empty?(socket.assigns.uploads.attachment.entries) do
      {:ok, []}
    else
      user_uuid = socket.assigns.current_user.uuid

      results =
        consume_uploaded_entries(socket, :attachment, fn meta, entry ->
          opts = [
            filename: entry.client_name,
            content_type: entry.client_type,
            size_bytes: entry.client_size,
            user_uuid: user_uuid
          ]

          case PhoenixKit.Modules.Storage.store_file(meta.path, opts) do
            {:ok, %{uuid: uuid}} -> {:ok, {:ok, uuid}}
            {:error, reason} -> {:ok, {:error, reason}}
          end
        end)

      case Enum.split_with(results, &match?({:ok, _}, &1)) do
        {oks, []} ->
          {:ok, Enum.map(oks, fn {:ok, uuid} -> uuid end)}

        {_, [{:error, reason} | _]} ->
          {:error, "Upload failed: #{inspect(reason)}"}
      end
    end
  end

  defp load_comments(socket) do
    comments =
      PhoenixKitComments.get_comment_tree(
        socket.assigns.resource_type,
        socket.assigns.resource_uuid
      )

    comment_count =
      PhoenixKitComments.count_comments(
        socket.assigns.resource_type,
        socket.assigns.resource_uuid,
        status: "published"
      )

    socket
    |> assign(:comments, comments)
    |> assign(:comment_count, comment_count)
  end

  attr(:comment, :map, required: true)
  attr(:current_user, :map, required: true)
  attr(:myself, :any, required: true)
  attr(:editing_uuid, :string, default: nil)
  attr(:editing_content, :string, default: "")

  def render_comment(assigns) do
    ~H"""
    <div class={[
      if(@comment.depth > 0, do: "ml-2 sm:ml-4 border-l-2 border-base-300", else: "")
    ]}>
      <div class="bg-base-200 rounded-lg p-3 sm:p-4">
        <%= if @comment.status == "deleted" do %>
          <div class="text-sm text-base-content/50 italic">[removed]</div>
        <% else %>
        <%!-- Comment Header --%>
        <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between mb-2">
          <div class="flex items-center gap-2 text-sm min-w-0 flex-wrap">
            <.icon name="hero-user-circle" class="w-5 h-5 text-base-content/60 shrink-0" />
            <span class="font-semibold truncate min-w-0 max-w-full">
              <%= if @comment.user do %>
                {@comment.user.email}
              <% else %>
                Unknown
              <% end %>
            </span>
            <span class="text-base-content/60 hidden sm:inline">&bull;</span>
            <span class="text-base-content/60 text-xs sm:text-sm whitespace-nowrap">
              {Calendar.strftime(@comment.inserted_at, "%b %d, %Y %I:%M %p")}
            </span>
          </div>

          <%!-- Comment Actions --%>
          <div class="flex gap-2 flex-wrap shrink-0">
            <button
              phx-click="reply_to"
              phx-value-id={@comment.uuid}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Reply
            </button>

            <%= if can_edit_comment?(@current_user, @comment) do %>
              <button
                phx-click="edit_comment"
                phx-value-id={@comment.uuid}
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" />
              </button>
            <% end %>

            <%= if can_delete_comment?(@current_user, @comment) do %>
              <button
                phx-click="delete_comment"
                phx-value-id={@comment.uuid}
                phx-target={@myself}
                class="btn btn-ghost btn-xs text-error"
                data-confirm="Are you sure you want to delete this comment?"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Comment Content (or Edit Form) --%>
        <%= if @editing_uuid == @comment.uuid do %>
          <.form for={%{}} phx-submit="save_edit" phx-target={@myself} class="space-y-2">
            <textarea
              name="content"
              class="textarea textarea-bordered w-full"
              rows="3"
              required
            ><%= @editing_content %></textarea>
            <div class="flex flex-wrap justify-end gap-2">
              <button
                type="button"
                phx-click="cancel_edit"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">
                <.icon name="hero-check" class="w-4 h-4 mr-1" /> Save
              </button>
            </div>
          </.form>
        <% else %>
          <%= if @comment.content && @comment.content != "" do %>
            <div class="text-base-content break-words">
              {@comment.content}
            </div>
          <% end %>
          <%= if gif = comment_gif(@comment) do %>
            <div class="mt-2">
              <img
                src={gif["url"]}
                loading="lazy"
                alt="GIF"
                class="rounded-lg w-full max-w-xs h-auto"
              />
            </div>
          <% end %>

          <%= if comment_media(@comment) != [] do %>
            <div class="mt-2 space-y-2">
              <%= for media <- comment_media(@comment) do %>
                <.render_attachment media={media} />
              <% end %>
            </div>
          <% end %>
        <% end %>
        <% end %>

        <%!-- Nested Comments (Replies) --%>
        <%= if @comment.children && length(@comment.children) > 0 do %>
          <div class="mt-4 space-y-3">
            <%= for child <- @comment.children do %>
              <.render_comment
                comment={child}
                current_user={@current_user}
                myself={@myself}
                editing_uuid={@editing_uuid}
                editing_content={@editing_content}
              />
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:media, :map, required: true)

  defp render_attachment(%{media: %{file: %{file_type: "image"} = file}} = assigns) do
    assigns = assign(assigns, :src, signed_url(file, "medium"))

    ~H"""
    <a href={signed_url(@media.file, "original")} target="_blank" rel="noopener">
      <img
        src={@src}
        loading="lazy"
        alt={@media.caption || @media.file.original_file_name}
        class="rounded-lg max-w-xs max-h-80 h-auto"
      />
    </a>
    """
  end

  defp render_attachment(%{media: %{file: %{file_type: "video"} = file}} = assigns) do
    assigns =
      assigns
      |> assign(:src, signed_url(file, "original"))
      |> assign(:poster, signed_url(file, "video_thumbnail"))

    ~H"""
    <video controls preload="metadata" poster={@poster} class="rounded-lg max-w-md w-full">
      <source src={@src} type={@media.file.mime_type} />
      Your browser does not support video playback.
    </video>
    """
  end

  defp render_attachment(%{media: %{file: %{file_type: "audio"} = file}} = assigns) do
    assigns = assign(assigns, :src, signed_url(file, "original"))

    ~H"""
    <audio controls preload="metadata" class="w-full max-w-md">
      <source src={@src} type={@media.file.mime_type} />
      Your browser does not support audio playback.
    </audio>
    """
  end

  defp render_attachment(%{media: %{file: file}} = assigns) do
    assigns =
      assigns
      |> assign(:href, signed_url(file, "original"))
      |> assign(:size_kb, div(file.size || 0, 1024))

    ~H"""
    <a
      href={@href}
      download={@media.file.original_file_name}
      class="inline-flex items-center gap-2 px-3 py-2 bg-base-200 rounded hover:bg-base-300"
    >
      <.icon name="hero-document-arrow-down" class="w-5 h-5 shrink-0" />
      <div class="min-w-0">
        <div class="text-sm font-medium truncate">{@media.file.original_file_name}</div>
        <div class="text-xs text-base-content/60">{@size_kb} KB</div>
      </div>
    </a>
    """
  end

  defp signed_url(%{uuid: uuid}, variant),
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(to_string(uuid), variant)

  defp comment_media(%{media: media}) when is_list(media), do: media
  defp comment_media(_), do: []

  defp can_edit_comment?(nil, _comment), do: false

  defp can_edit_comment?(user, comment) do
    user.uuid == comment.user_uuid or user_is_admin?(user)
  end

  defp can_delete_comment?(nil, _comment), do: false

  defp can_delete_comment?(user, comment) do
    user.uuid == comment.user_uuid or user_is_admin?(user)
  end

  defp user_is_admin?(nil), do: false

  defp user_is_admin?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp comment_gif(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "giphy") do
      %{"url" => url} = gif when is_binary(url) and url != "" -> gif
      _ -> nil
    end
  end

  defp comment_gif(_), do: nil

  defp first_error_message(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{field, {msg, _opts}} | _] -> "#{Phoenix.Naming.humanize(field)} #{msg}"
      _ -> nil
    end
  end

  defp attachment_icon("image/" <> _), do: "hero-photo"
  defp attachment_icon("video/" <> _), do: "hero-film"
  defp attachment_icon("audio/" <> _), do: "hero-musical-note"
  defp attachment_icon(_), do: "hero-document"

  defp upload_error_label(:too_large), do: "File too large"
  defp upload_error_label(:too_many_files), do: "Too many files"
  defp upload_error_label(:not_accepted), do: "File type not allowed"
  defp upload_error_label(other), do: "Upload error: #{inspect(other)}"
end
