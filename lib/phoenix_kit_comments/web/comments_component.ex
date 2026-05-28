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

  # Leaf is an optional dep. When present, the comment form swaps
  # textareas for `<.live_component module={Leaf}>`. Without leaf
  # installed, the form falls back to plain textareas with no
  # behavior change. `@compile {:no_warn_undefined, [Leaf]}` keeps
  # dialyzer / compiler quiet in the leaf-absent build; runtime
  # behavior is guarded by `leaf_available?/0`.
  @compile {:no_warn_undefined, [Leaf]}

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
     |> assign(:composer_open?, false)
     |> assign(:new_comment, "")
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")
     # Per-decoration inline-edit state. The uuid is a
     # `{metadata_key, comment_uuid}` tuple (or nil) so two different
     # decoration kinds on the same comment don't collide.
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")
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

  # Leaf content forwarded from a host LV via `forward_leaf_event/2`.
  # `:draft` updates the new-comment / reply assign; `:edit` updates
  # the inline-edit assign. Either way the next form submit reads
  # from socket.assigns instead of params (Leaf doesn't bubble
  # form-collectable elements to the parent form).
  @impl true
  def update(%{leaf_content_changed: %{kind: kind, content: content}}, socket)
      when kind in [:draft, :reply] do
    {:ok, assign(socket, :new_comment, content)}
  end

  def update(%{leaf_content_changed: %{kind: :edit, content: content}}, socket) do
    {:ok, assign(socket, :editing_content, content)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:enabled, fn -> true end)
      |> assign_new(:show_likes, fn -> false end)
      |> assign_new(:title, fn -> "Comments" end)
      |> assign_new(:form_extras, fn -> [] end)
      |> assign_new(:current_user, fn -> nil end)
      # Optional per-comment decoration registry. Generic surface
      # for rendering an external label above the comment body,
      # driven by one of the comment's `metadata[key]` fields. The
      # comments package stays domain-agnostic; the caller declares
      # which metadata field to read and what label to display for
      # each known value.
      #
      # Shape:
      #
      #     %{
      #       <metadata_key> => %{
      #         <metadata_value> => %{
      #           label: <string>,           # required — what to render
      #           on_save: <atom> | nil      # optional — fires send_update
      #                                      # to parent_module/parent_id
      #                                      # when set; nil = read-only
      #         },
      #         ...
      #       },
      #       ...
      #     }
      #
      # Example consumers:
      #   PhoenixKit's MediaCanvasViewer for annotation titles:
      #     %{"annotation_uuid" => %{
      #         "abc-uuid" => %{label: "Sky shot", on_save: :annotation_title_updated}
      #       }}
      #   Hypothetical post-category decoration:
      #     %{"category_id" => %{
      #         "42" => %{label: "Releases", on_save: nil}
      #       }}
      #
      # The first matching decoration wins per comment; multiple
      # decorations per comment aren't supported in this iteration.
      |> assign_new(:comment_decorations, fn -> %{} end)
      # Parent component to receive `send_update` when a decoration
      # is inline-edited (only relevant for decorations whose
      # entry sets `on_save`). The payload shape is:
      #
      #     %{action: <on_save atom>,
      #       metadata_key: <string>,
      #       metadata_value: <string>,
      #       label: <new string>}
      |> assign_new(:parent_module, fn -> nil end)
      |> assign_new(:parent_id, fn -> nil end)
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
    # When Leaf is the editor, content lives in socket.assigns
    # (kept fresh by forwarded `:leaf_changed` messages from the
    # host LV). The form submit doesn't carry Leaf's contenteditable.
    # Falls back to params for the plain-textarea path.
    comment_text =
      params
      |> Map.get("comment")
      |> case do
        nil ->
          if leaf_available?(),
            do: socket.assigns.new_comment,
            else: ""

        text ->
          text
      end

    metadata_params =
      params
      |> Map.get("metadata", %{})
      |> Map.delete("giphy")

    metadata =
      case socket.assigns.giphy_selected do
        nil -> metadata_params
        gif -> Map.put(metadata_params, "giphy", gif)
      end

    case consume_attachments(socket) do
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:ok, file_uuids} ->
        attrs = %{
          content: comment_text,
          parent_uuid: socket.assigns.reply_to,
          metadata: metadata,
          attachment_file_uuids: file_uuids
        }

        case PhoenixKitComments.create_comment(
               socket.assigns.resource_type,
               socket.assigns.resource_uuid,
               socket.assigns.current_user.uuid,
               attrs
             ) do
          {:ok, _comment} ->
            reset_leaf_draft_editor(socket.assigns.id, socket.assigns.reply_to)

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
             |> assign(:composer_open?, false)
             |> assign(:giphy_selected, nil)
             |> assign(:giphy_open?, false)
             |> assign(:giphy_results, [])
             |> assign(:giphy_query, "")
             |> assign(:attach_menu_open?, false)
             |> assign(:recording_audio?, false)
             |> load_comments()
             |> put_flash(:info, "Comment added")}

          {:error, %Ecto.Changeset{} = changeset} ->
            message = first_error_message(changeset) || "Failed to add comment"
            {:noreply, put_flash(socket, :error, message)}

          {:error, :empty_comment} ->
            {:noreply, put_flash(socket, :error, "Comment can't be empty")}

          {:error, :attachments_disabled} ->
            {:noreply, put_flash(socket, :error, "Attachments are disabled")}

          {:error, :too_many_attachments} ->
            max = PhoenixKitComments.get_max_attachments()
            {:noreply, put_flash(socket, :error, "Up to #{max} attachments per comment")}

          {:error, _other} ->
            {:noreply, put_flash(socket, :error, "Failed to add comment")}
        end
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
  def handle_event("open_composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, true)}
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
     |> assign(:reply_to, nil)
     |> assign(:composer_open?, false)
     |> assign(:giphy_selected, nil)
     |> assign(:giphy_open?, false)
     |> assign(:giphy_results, [])
     |> assign(:giphy_query, "")
     |> assign(:attach_menu_open?, false)}
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
     |> assign(:composer_open?, false)
     |> assign(:new_comment, "")
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
          # When the comment has a matching decoration entry,
          # pre-fill `:editing_decoration_value` so the unified
          # edit form opens with the live label. No-op for comments
          # with no decoration — the input renders behind a guard.
          decoration_label =
            case find_decoration_for_comment(comment, socket.assigns.comment_decorations) do
              %{label: label} when is_binary(label) -> label
              _ -> ""
            end

          {:noreply,
           socket
           |> assign(:editing_uuid, comment_uuid)
           |> assign(:editing_content, comment.content)
           |> assign(:editing_decoration_value, decoration_label)
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
     |> assign(:editing_content, "")
     |> assign(:editing_decoration_value, "")}
  end

  @impl true
  def handle_event("save_edit", params, socket) do
    comment_uuid = socket.assigns.editing_uuid

    # Same Leaf-vs-textarea source split as `add_comment`.
    content =
      params
      |> Map.get("content")
      |> case do
        nil ->
          if leaf_available?(),
            do: socket.assigns.editing_content,
            else: ""

        text ->
          text
      end

    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        if comment.resource_type != socket.assigns.resource_type or
             comment.resource_uuid != socket.assigns.resource_uuid do
          {:noreply, put_flash(socket, :error, "Invalid comment for this resource")}
        else
          # If the edit form carried a "label" field (i.e. the
          # comment has a matching decoration with an `on_save`
          # action), forward the new label to the parent. Comment-
          # content save below is unconditional. Both updates fire
          # in the same tick.
          maybe_forward_decoration_update(socket, comment, params)
          do_save_edit(socket, comment, content)
        end
    end
  end

  # ── Decoration inline-edit ───────────────────────────────────
  # Decorations live on the consumer's parent resource (e.g. an
  # annotation's title in PhoenixKit's MediaCanvasViewer), not on
  # the comment row. We provide UI + state plumbing; the parent
  # component owns the actual write via the configured per-entry
  # `:on_save` action atom.

  @impl true
  def handle_event("begin_decoration_edit", %{"uuid" => comment_uuid}, socket) do
    case find_decoration_for_comment_uuid(comment_uuid, socket) do
      %{label: label, on_save: on_save, metadata_key: metadata_key} when not is_nil(on_save) ->
        {:noreply,
         socket
         |> assign(:editing_decoration_uuid, {metadata_key, comment_uuid})
         |> assign(:editing_decoration_value, label || "")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_decoration_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")}
  end

  @impl true
  def handle_event("save_decoration", %{"uuid" => comment_uuid, "label" => label}, socket) do
    case find_decoration_for_comment_uuid(comment_uuid, socket) do
      %{on_save: on_save, metadata_key: metadata_key, metadata_value: metadata_value}
      when not is_nil(on_save) ->
        if socket.assigns.parent_module && socket.assigns.parent_id do
          Phoenix.LiveView.send_update(socket.assigns.parent_module,
            id: socket.assigns.parent_id,
            action: on_save,
            metadata_key: metadata_key,
            metadata_value: metadata_value,
            label: String.trim(label)
          )
        end

      _ ->
        :ok
    end

    {:noreply,
     socket
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")}
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

  # Forward a decoration label captured by the comment-edit form
  # to the parent component (only when the comment has a matching
  # decoration entry with an `:on_save` action). Called from
  # `save_edit` alongside the comment-content write so a single
  # Save click persists both surfaces in one tick.
  defp maybe_forward_decoration_update(socket, comment, params) do
    label = Map.get(params, "label")
    parent_module = socket.assigns.parent_module
    parent_id = socket.assigns.parent_id

    with true <- is_binary(label),
         true <- parent_module != nil and parent_id != nil,
         %{on_save: on_save, metadata_key: metadata_key, metadata_value: metadata_value}
         when not is_nil(on_save) <-
           find_decoration_for_comment(comment, socket.assigns.comment_decorations) do
      Phoenix.LiveView.send_update(parent_module,
        id: parent_id,
        action: on_save,
        metadata_key: metadata_key,
        metadata_value: metadata_value,
        label: String.trim(label)
      )
    end

    :ok
  end

  # Finds the first decoration entry that matches a comment. Scans
  # `comment_decorations` in iteration order; returns a map with
  # `:label, :on_save, :metadata_key, :metadata_value` or `nil`.
  # Multi-decoration support (rendering more than one label per
  # comment) is intentionally out of scope for now.
  defp find_decoration_for_comment(comment, decorations) when is_map(decorations) do
    metadata = comment.metadata || %{}

    Enum.find_value(decorations, fn {metadata_key, values_map} ->
      with value when is_binary(value) <- Map.get(metadata, metadata_key),
           %{} = entry <- Map.get(values_map, value) do
        entry
        |> Map.put_new(:on_save, nil)
        |> Map.merge(%{metadata_key: metadata_key, metadata_value: value})
      else
        _ -> nil
      end
    end)
  end

  defp find_decoration_for_comment(_, _), do: nil

  # Same as above but resolves the comment from the in-memory tree
  # by uuid first. Used by the title-only click-to-edit flow which
  # only carries the comment uuid in its phx-value-uuid.
  defp find_decoration_for_comment_uuid(comment_uuid, socket) do
    case find_comment_in_tree(socket.assigns.comments, comment_uuid) do
      nil -> nil
      comment -> find_decoration_for_comment(comment, socket.assigns.comment_decorations)
    end
  end

  defp find_comment_in_tree([], _uuid), do: nil

  defp find_comment_in_tree([comment | rest], uuid) do
    if to_string(comment.uuid) == to_string(uuid) do
      comment
    else
      find_comment_in_tree(comment.children || [], uuid) ||
        find_comment_in_tree(rest, uuid)
    end
  end

  defp find_comment_in_tree(_, _), do: nil

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
  attr(:component_id, :string, required: true)
  attr(:editing_uuid, :string, default: nil)
  attr(:editing_content, :string, default: "")
  attr(:comment_decorations, :map, default: %{})
  attr(:editing_decoration_uuid, :any, default: nil)
  attr(:editing_decoration_value, :string, default: "")
  attr(:reply_to, :string, default: nil)
  attr(:new_comment, :string, default: "")
  attr(:max_length, :integer, required: true)
  attr(:uploads, :map, required: true)
  attr(:attachments_enabled?, :boolean, required: true)
  attr(:max_attachments, :integer, required: true)
  attr(:max_attachment_size_mb, :integer, required: true)

  def render_comment(assigns) do
    decoration = find_decoration_for_comment(assigns.comment, assigns.comment_decorations)

    # Convenience: the pre-existing data-annotation-uuid attr on the
    # rendered wrapper. Kept for callers that target shapes via that
    # selector (predates the decoration refactor).
    annotation_uuid = get_in(assigns.comment.metadata || %{}, ["annotation_uuid"])

    assigns =
      assigns
      |> assign(:decoration, decoration)
      |> assign(:annotation_uuid, annotation_uuid)
      |> assign(
        :decoration_editing?,
        decoration && match?({_, _}, assigns.editing_decoration_uuid) &&
          assigns.editing_decoration_uuid ==
            {decoration.metadata_key, assigns.comment.uuid}
      )

    ~H"""
    <div
      data-comment-uuid={@comment.uuid}
      data-annotation-uuid={@annotation_uuid}
      class={[
        if(@comment.depth > 0, do: "ml-2 sm:ml-4 border-l-2 border-base-300", else: "")
      ]}
    >
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

        <%!-- Decoration label (when this comment matches an entry in   --%>
        <%!-- :comment_decorations). Sits BETWEEN the user-info         --%>
        <%!-- header and the comment body so the hierarchy reads:       --%>
        <%!-- who/when → topic → comment.                                --%>
        <%!--                                                            --%>
        <%!-- Read-only when the decoration's `:on_save` is nil;        --%>
        <%!-- click-to-edit when set. The pencil icon only appears on   --%>
        <%!-- hover so the header doesn't shout "edit me" until the     --%>
        <%!-- user reaches it.                                           --%>
        <%!--                                                            --%>
        <%!-- Suppressed during comment-edit (@editing_uuid matches) —  --%>
        <%!-- the unified edit form below carries its own label input.  --%>
        <%= if @decoration && @editing_uuid != @comment.uuid do %>
          <div class="mb-2">
            <%= if @decoration_editing? do %>
              <.form
                for={%{}}
                phx-submit="save_decoration"
                phx-target={@myself}
                class="flex items-center gap-2"
              >
                <input type="hidden" name="uuid" value={@comment.uuid} />
                <input
                  type="text"
                  name="label"
                  value={@editing_decoration_value}
                  maxlength="200"
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  phx-keydown="cancel_decoration_edit"
                  phx-key="escape"
                  phx-target={@myself}
                  class="input input-bordered input-sm flex-1 text-sm font-semibold"
                />
                <button type="submit" class="btn btn-primary btn-xs">
                  <.icon name="hero-check" class="w-3.5 h-3.5" />
                </button>
                <button
                  type="button"
                  phx-click="cancel_decoration_edit"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </.form>
            <% else %>
              <div
                class={[
                  "group flex items-center gap-1",
                  @decoration.on_save && "cursor-pointer"
                ]}
                phx-click={@decoration.on_save && "begin_decoration_edit"}
                phx-value-uuid={@comment.uuid}
                phx-target={@myself}
              >
                <h4 class={[
                  "text-sm font-semibold break-words flex-1 min-w-0",
                  @decoration.on_save && "group-hover:text-primary transition-colors"
                ]}>
                  {@decoration.label}
                </h4>
                <%= if @decoration.on_save do %>
                  <.icon
                    name="hero-pencil-square"
                    class="w-3.5 h-3.5 opacity-0 group-hover:opacity-60 shrink-0 transition-opacity"
                  />
                <% end %>
              </div>
            <% end %>
            <hr class="mt-1 border-base-300" />
          </div>
        <% end %>

        <%!-- Comment Content (or Edit Form) --%>
        <%= if @editing_uuid == @comment.uuid do %>
          <.form for={%{}} phx-submit="save_edit" phx-target={@myself} class="space-y-2">
            <%!-- When this comment has a decoration with an `on_save`    --%>
            <%!-- action, the edit form opens label + body together.      --%>
            <%!-- Save writes both: comment content through the normal    --%>
            <%!-- `do_save_edit` path, decoration label via send_update   --%>
            <%!-- to the parent. The standalone click-the-label flow      --%>
            <%!-- above stays as a shortcut for "just rename, don't       --%>
            <%!-- re-edit the body."                                       --%>
            <%= if @decoration && @decoration.on_save do %>
              <input
                type="text"
                name="label"
                value={@editing_decoration_value}
                maxlength="200"
                placeholder="Title"
                class="input input-bordered input-sm w-full text-sm font-semibold"
              />
              <hr class="border-base-300" />
            <% end %>
            <%!-- Edit body. Leaf when available, plain textarea fallback. --%>
            <%!-- Editor id encodes the comment uuid so morphdom remounts  --%>
            <%!-- a fresh Leaf when the user opens edit on a different     --%>
            <%!-- comment. Save reads from socket.assigns.editing_content   --%>
            <%!-- (kept fresh via forwarded :leaf_changed events).         --%>
            <%= if leaf_available?() do %>
              <.live_component
                module={Leaf}
                id={edit_editor_id(@component_id, @comment.uuid)}
                content={@editing_content || ""}
                preset={:advanced}
                placeholder="Edit your comment..."
                height="200px"
                debounce={400}
                upload_handler={nil}
                sync_input_name="content"
                loading_preset={:random}
                loading_text={nil}
              />
            <% else %>
              <textarea
                name="content"
                class="textarea textarea-bordered w-full"
                rows="3"
                required
              ><%= @editing_content %></textarea>
            <% end %>
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

        <%= if @reply_to == @comment.uuid do %>
          <div class="mt-3 border-l-2 border-primary/40 pl-3">
            <div class="text-xs font-medium text-base-content/60 mb-2">Replying here</div>
            <.form
              for={%{}}
              phx-submit="add_comment"
              phx-change="update_comment_draft"
              phx-target={@myself}
              class="space-y-2"
            >
              <%= if leaf_available?() do %>
                <.live_component
                  module={Leaf}
                  id={reply_editor_id(@component_id, @comment.uuid)}
                  content={@new_comment || ""}
                  preset={:advanced}
                  placeholder="Write a reply..."
                  height="160px"
                  debounce={400}
                  upload_handler={nil}
                  sync_input_name="comment"
                  loading_preset={:random}
                  loading_text={nil}
                />
              <% else %>
                <textarea
                  name="comment"
                  placeholder="Write a reply..."
                  class="textarea textarea-bordered w-full"
                  rows="3"
                  phx-debounce="150"
                ><%= @new_comment %></textarea>
              <% end %>

              <div class={[
                "text-xs text-right",
                if(String.length(@new_comment) > @max_length,
                  do: "text-error font-semibold",
                  else: "text-base-content/60"
                )
              ]}>
                {String.length(@new_comment)} / {@max_length}
              </div>

              <%= if @attachments_enabled? do %>
                <.live_file_input upload={@uploads.attachment} class="sr-only" />

                <%= if @uploads.attachment.entries != [] or @uploads.attachment.errors != [] do %>
                  <div class="space-y-2">
                    <%= for entry <- @uploads.attachment.entries do %>
                      <div class="flex items-center gap-3 bg-base-200 rounded p-2">
                        <.icon
                          name={attachment_icon(entry.client_type)}
                          class="w-5 h-5 shrink-0 text-base-content/60"
                        />
                        <div class="flex-1 min-w-0">
                          <div class="text-sm font-medium truncate">{entry.client_name}</div>
                          <%= if entry.progress > 0 and entry.progress < 100 do %>
                            <progress
                              class="progress progress-primary w-full h-1"
                              value={entry.progress}
                              max="100"
                            ></progress>
                          <% end %>
                        </div>
                        <button
                          type="button"
                          phx-click="cancel_upload"
                          phx-value-ref={entry.ref}
                          phx-target={@myself}
                          aria-label={"Remove #{entry.client_name}"}
                          class="btn btn-ghost btn-xs"
                        >
                          <.icon name="hero-x-mark" class="w-4 h-4" />
                        </button>
                      </div>
                    <% end %>

                    <%= for err <- upload_errors(@uploads.attachment) do %>
                      <p class="text-xs text-error">{upload_error_label(err)}</p>
                    <% end %>
                    <%= for entry <- @uploads.attachment.entries, err <- upload_errors(@uploads.attachment, entry) do %>
                      <p class="text-xs text-error">
                        {entry.client_name}: {upload_error_label(err)}
                      </p>
                    <% end %>
                  </div>
                <% end %>
              <% end %>

              <div class="flex flex-wrap justify-end gap-2">
                <%= if @attachments_enabled? do %>
                  <label
                    for={@uploads.attachment.ref}
                    class="btn btn-ghost btn-sm cursor-pointer"
                    title={"Up to #{@max_attachments} files, max #{@max_attachment_size_mb}MB each"}
                  >
                    <.icon name="hero-paper-clip" class="w-4 h-4 mr-1" /> Attach
                  </label>
                <% end %>
                <button
                  type="button"
                  phx-click="cancel_new_comment"
                  phx-target={@myself}
                  class="btn btn-ghost btn-sm"
                >
                  Hide
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> Post Reply
                </button>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Nested Comments (Replies) --%>
        <%= if @comment.children && length(@comment.children) > 0 do %>
          <div class="mt-4 space-y-3">
            <%= for child <- @comment.children do %>
              <.render_comment
                comment={child}
                current_user={@current_user}
                myself={@myself}
                component_id={@component_id}
                editing_uuid={@editing_uuid}
                editing_content={@editing_content}
                comment_decorations={@comment_decorations}
                editing_decoration_uuid={@editing_decoration_uuid}
                editing_decoration_value={@editing_decoration_value}
                reply_to={@reply_to}
                new_comment={@new_comment}
                max_length={@max_length}
                uploads={@uploads}
                attachments_enabled?={@attachments_enabled?}
                max_attachments={@max_attachments}
                max_attachment_size_mb={@max_attachment_size_mb}
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

  # ── Leaf editor integration ──────────────────────────────────
  # Leaf (the optional rich-text editor) is a LiveComponent that
  # sends `{:leaf_changed, %{editor_id, markdown, html}}` to
  # `self()` — i.e. the parent LiveView process, NOT the
  # CommentsComponent (which is itself a LiveComponent). Host LVs
  # that embed CommentsComponent must catch those messages and
  # call `forward_leaf_event/2` so the component can keep its
  # draft / edit assigns in sync. Without forwarding, Leaf still
  # works visually but the form has no content to submit.
  #
  # ## Host wiring (one-liner per LiveView)
  #
  #     def handle_info({:leaf_changed, _} = msg, socket) do
  #       PhoenixKitComments.Web.CommentsComponent.forward_leaf_event(msg, socket)
  #     end
  #
  # ## Editor ID namespace
  #
  # The component owns the editor IDs and gates them with
  # `"pk-comments:<component_id>:..."` so the forwarder routes
  # only its own events. Other Leaf instances in the same host LV
  # (e.g. a post-content editor) are passed through unchanged via
  # `:pass`, letting the host's own handler match them.

  @doc """
  Forward a Leaf content-changed message from a host LiveView's
  `handle_info` into the comments component. Routes only events
  whose `editor_id` starts with `"pk-comments:"`; returns `:pass`
  for unrelated editors so the caller can fall through to its own
  handler.

  ## Example

      def handle_info({:leaf_changed, _} = msg, socket) do
        PhoenixKitComments.Web.CommentsComponent.forward_leaf_event(msg, socket)
      end

  Returns `{:noreply, socket}` on a match (already wrapped, ready
  to return from handle_info), or `:pass` when the editor isn't
  ours.
  """
  def forward_leaf_event(
        {:leaf_changed, %{editor_id: editor_id, markdown: markdown}},
        socket
      )
      when is_binary(editor_id) do
    case parse_editor_id(editor_id) do
      {:ok, component_id, kind} ->
        Phoenix.LiveView.send_update(__MODULE__,
          id: component_id,
          leaf_content_changed: %{kind: kind, content: markdown || ""}
        )

        {:noreply, socket}

      :pass ->
        :pass
    end
  end

  def forward_leaf_event(_msg, _socket), do: :pass

  # Parse "pk-comments:<component_id>:<kind>(:rest...)" into
  # `{:ok, component_id, kind}`. The kind is `:draft` for the
  # new-comment / reply form (one per component) or `:edit` for
  # the inline edit form (also one at a time per component).
  defp parse_editor_id("pk-comments:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [component_id, "draft"] -> {:ok, component_id, :draft}
      [component_id, "reply", _comment_uuid] -> {:ok, component_id, :reply}
      [component_id, "edit", _comment_uuid] -> {:ok, component_id, :edit}
      _ -> :pass
    end
  end

  defp parse_editor_id(_), do: :pass

  defp leaf_available?, do: Code.ensure_loaded?(Leaf)

  defp draft_editor_id(component_id), do: "pk-comments:#{component_id}:draft"

  defp reply_editor_id(component_id, comment_uuid),
    do: "pk-comments:#{component_id}:reply:#{comment_uuid}"

  defp edit_editor_id(component_id, comment_uuid),
    do: "pk-comments:#{component_id}:edit:#{comment_uuid}"

  defp reset_leaf_draft_editor(component_id, reply_to) do
    if leaf_available?() do
      editor_id =
        case reply_to do
          nil -> draft_editor_id(component_id)
          comment_uuid -> reply_editor_id(component_id, comment_uuid)
        end

      Phoenix.LiveView.send_update(Leaf,
        id: editor_id,
        action: :set_content,
        content: ""
      )
    end
  end
end
