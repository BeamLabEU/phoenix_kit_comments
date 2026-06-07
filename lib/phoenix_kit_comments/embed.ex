defmodule PhoenixKitComments.Embed do
  @moduledoc """
  Host-side wiring for embedding `PhoenixKitComments.Web.CommentsComponent`.

  ## Why this exists

  The comment composer's rich-text (Leaf) editor reports its content to the
  **host LiveView** via a `{:leaf_changed, ...}` process message — a
  `LiveComponent` has no `handle_info/2` of its own, so the message can only
  land in the host. On submit, `CommentsComponent` reads its `new_comment`
  assign (the form params don't carry Leaf's contenteditable). Without the
  host forwarding `{:leaf_changed, ...}` back into the component via
  `CommentsComponent.forward_leaf_event/2`, the editor's content never
  reaches it and "Post comment" silently no-ops.

  This is easy to forget (it's a process-message hop, invisible in the
  component's own markup). `use PhoenixKitComments.Embed` wires it for you.

  ## Usage

      defmodule MyAppWeb.ThingShowLive do
        use MyAppWeb, :live_view
        use PhoenixKitComments.Embed
        # ...render <.live_component module={PhoenixKitComments.Web.CommentsComponent} ... />
      end

  ## How it composes

  The forward is attached as a `:handle_info` lifecycle hook in an
  `on_mount/4` (not injected `handle_info` clauses), so it **composes** with
  a host that already defines its own `handle_info` — no "clauses should be
  grouped" warning, no clobbering. Non-comments messages pass straight
  through (`{:cont, socket}`); a `{:leaf_changed, ...}` for one of our
  editors is forwarded and halted. Mirrors the lifecycle-hook approach
  `PhoenixKitWeb.Components.MediaBrowser.Embed` uses for the same purpose.

  ## Hard-dep only

  `use` is compile-time, so only hosts that **depend on**
  `phoenix_kit_comments` can use this. A host where comments is *optional*
  (a soft dep) must instead resolve and call `forward_leaf_event/2` at
  runtime — see `phoenix_kit_staff`'s `PersonShowLive`:

      def handle_info({:leaf_changed, _} = msg, socket) do
        case Code.ensure_loaded(PhoenixKitComments.Web.CommentsComponent) do
          {:module, mod} ->
            case mod.forward_leaf_event(msg, socket) do
              # A comments editor — already handled.
              {:noreply, _} = ok -> ok
              # `:pass` means the event is *not* a comments editor (its
              # `editor_id` isn't `"pk-comments:"`-prefixed). Fall through
              # to the host's own Leaf handling here; the bare
              # `{:noreply, socket}` only fits a host whose *only* Leaf
              # editor is the comments composer — otherwise it silently
              # swallows the host's own editor events.
              :pass -> {:noreply, socket}
            end

          # Comments package isn't installed — nothing to forward.
          _ ->
            {:noreply, socket}
        end
      end
  """

  alias PhoenixKitComments.Web.CommentsComponent

  defmacro __using__(_opts) do
    quote do
      on_mount(PhoenixKitComments.Embed)
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(
        socket,
        :phoenix_kit_comments_leaf,
        :handle_info,
        &__forward_leaf__/2
      )

    {:cont, socket}
  end

  @doc false
  # Lifecycle-hook body. `{:cont, socket}` lets the host's own handle_info
  # (and other hooks) run; `{:halt, socket}` consumes the message.
  def __forward_leaf__({:leaf_changed, _} = msg, socket) do
    case CommentsComponent.forward_leaf_event(msg, socket) do
      {:noreply, socket} -> {:halt, socket}
      # `:pass` (editor isn't ours) or any unexpected return — let the
      # message continue to the host / other hooks rather than swallow it.
      _ -> {:cont, socket}
    end
  end

  def __forward_leaf__(_msg, socket), do: {:cont, socket}
end
