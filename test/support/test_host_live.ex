defmodule PhoenixKitComments.Test.HostLive do
  @moduledoc """
  A minimal host page that embeds `CommentsComponent`, the way a consuming
  application does.

  The admin LiveViews in `test/integration/` cover the moderation screens.
  They cannot cover the component: it is a `live_component` with its own
  event handlers, and its riskiest behaviour — the module kill switch, the
  viewer's role, and which parts of a submitted payload are allowed to reach
  `comment.metadata` — only exists inside a host. Without a host page, those
  paths had no test at all, which is how a client-supplied metadata key that
  links a comment to somebody else's record went unnoticed.

  `:decoration_keys` is passed through from the URL so a test can host the
  component the way core's MediaCanvasViewer does (declaring
  `"annotation_uuid"`) or the way a host that declares nothing does.
  """
  use Phoenix.LiveView, layout: {PhoenixKitComments.Test.Layouts, :app}

  alias PhoenixKitComments.Web.CommentsComponent

  @impl true
  def mount(params, _session, socket) do
    decoration_keys =
      case params["decoration_keys"] do
        nil -> []
        "" -> []
        csv -> String.split(csv, ",")
      end

    {:ok,
     socket
     |> assign(:resource_uuid, params["resource_uuid"])
     |> assign(:decoration_keys, decoration_keys)
     |> assign(:current_user, socket.assigns[:phoenix_kit_current_user])
     # Passed like a host that already holds the viewer's scope; without it
     # the component builds one from the database for a user the tests never
     # granted anything.
     |> assign(:pk_scope, socket.assigns[:phoenix_kit_current_scope])
     # `?no_scope=1` embeds the component WITHOUT `pk_scope`, the way the CRM
     # and projects hosts do, so it builds the viewer's scope itself.
     |> assign(:no_scope, params["no_scope"] == "1")
     # `?second_thread=<uuid>` embeds a second thread on the same page, the
     # way a host listing several records with their comments does.
     |> assign(:second_thread, params["second_thread"])
     |> assign(:comments_updated, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div id="host-status">{inspect(@comments_updated)}</div>
      <div id="first-thread">
      <.live_component
        :if={!@no_scope}
        module={CommentsComponent}
        id="test-thread"
        resource_type="test_resource"
        resource_uuid={@resource_uuid}
        current_user={@current_user}
        pk_scope={@pk_scope}
        decoration_keys={@decoration_keys}
      />
      <.live_component
        :if={@no_scope}
        module={CommentsComponent}
        id="test-thread"
        resource_type="test_resource"
        resource_uuid={@resource_uuid}
        current_user={@current_user}
        decoration_keys={@decoration_keys}
      />
      </div>
      <div :if={@second_thread} id="second-thread">
        <.live_component
          module={CommentsComponent}
          id="test-thread-2"
          resource_type="test_resource"
          resource_uuid={@second_thread}
          current_user={@current_user}
          pk_scope={@pk_scope}
        />
      </div>
    </div>
    """
  end

  # A host re-render with no new data — the cheapest way for a test to make
  # the component's `update/2` run again, which is what a settings change
  # elsewhere relies on to take effect.
  @impl true
  def handle_event("host_refresh", _params, socket) do
    {:noreply, assign(socket, :comments_updated, :refreshed)}
  end

  @impl true
  def handle_info({:comments_updated, payload}, socket) do
    {:noreply, assign(socket, :comments_updated, payload)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
