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

  ## Parent Notifications

  After create/delete, sends to the parent LiveView:

      {:comments_updated, %{resource_type: "post", resource_uuid: uuid, action: :created | :deleted}}
  """

  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Users.Roles

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:comments, [])
     |> assign(:comment_count, 0)
     |> assign(:reply_to, nil)
     |> assign(:new_comment, "")
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:enabled, fn -> true end)
      |> assign_new(:show_likes, fn -> false end)
      |> assign_new(:title, fn -> "Comments" end)

    socket =
      if changed?(socket, :resource_uuid) or socket.assigns.comments == [] do
        load_comments(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment_text}, socket) do
    if comment_text != "" do
      parent_uuid = socket.assigns.reply_to

      attrs = %{
        content: comment_text,
        parent_uuid: parent_uuid
      }

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
           |> load_comments()
           |> put_flash(:info, "Comment added")}

        {:error, _changeset} ->
          {:noreply, socket |> put_flash(:error, "Failed to add comment")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_uuid}, socket) do
    {:noreply, assign(socket, :reply_to, comment_uuid)}
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
           |> assign(:editing_content, comment.content)}
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
    if can_edit_comment?(socket.assigns.current_user, comment) do
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
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this comment")}
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
      if(@comment.depth > 0, do: "ml-4 border-l-2 border-base-300", else: "")
    ]}>
      <div class="bg-base-200 rounded-lg p-4">
        <%!-- Comment Header --%>
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2 text-sm">
            <.icon name="hero-user-circle" class="w-5 h-5 text-base-content/60" />
            <span class="font-semibold">
              <%= if @comment.user do %>
                {@comment.user.email}
              <% else %>
                Unknown
              <% end %>
            </span>
            <span class="text-base-content/60">&bull;</span>
            <span class="text-base-content/60">
              {Calendar.strftime(@comment.inserted_at, "%b %d, %Y %I:%M %p")}
            </span>
          </div>

          <%!-- Comment Actions --%>
          <div class="flex gap-2">
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
            <div class="flex justify-end gap-2">
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
          <div class="text-base-content">
            {@comment.content}
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

  defp can_edit_comment?(user, comment) do
    user.uuid == comment.user_uuid or user_is_admin?(user)
  end

  defp can_delete_comment?(user, comment) do
    user.uuid == comment.user_uuid or user_is_admin?(user)
  end

  defp user_is_admin?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end
end
