defmodule PhoenixKitComments.EmbedTest do
  @moduledoc """
  Pins the `PhoenixKitComments.Embed` host-wiring contract: the `on_mount`
  attaches a `:handle_info` lifecycle hook, and that hook forwards a comments
  composer's `{:leaf_changed, …}` to the component (`:halt`) while letting every
  other message — including a host's own non-comments Leaf editor — pass through
  (`:cont`). Unit-level: no DB, no running LiveView (`send_update` only enqueues
  a message to the test process; routing is decided by the editor id).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitComments.Embed

  # A socket with the lifecycle map initialized — `attach_hook/4` reads
  # `socket.private.lifecycle`, which a real LiveView sets up at mount.
  defp socket do
    %Phoenix.LiveView.Socket{private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}}
  end

  describe "on_mount/4" do
    test "attaches the :phoenix_kit_comments_leaf :handle_info hook" do
      assert {:cont, socket} = Embed.on_mount(:default, %{}, %{}, socket())

      hook_ids =
        socket.private
        |> Map.fetch!(:lifecycle)
        |> Map.fetch!(:handle_info)
        |> Enum.map(& &1.id)

      assert :phoenix_kit_comments_leaf in hook_ids
    end
  end

  describe "__forward_leaf__/2 routing" do
    test "halts a :leaf_changed from the comments composer (pk-comments editor id)" do
      msg = {:leaf_changed, %{editor_id: "pk-comments:thread-1:draft:top", markdown: "hi"}}
      assert {:halt, %Phoenix.LiveView.Socket{}} = Embed.__forward_leaf__(msg, socket())
    end

    test "continues a :leaf_changed from a host's own non-comments Leaf editor" do
      msg = {:leaf_changed, %{editor_id: "my-app:body-editor", markdown: "hi"}}
      assert {:cont, %Phoenix.LiveView.Socket{}} = Embed.__forward_leaf__(msg, socket())
    end

    test "continues a :leaf_changed whose payload is missing an editor id" do
      assert {:cont, %Phoenix.LiveView.Socket{}} =
               Embed.__forward_leaf__({:leaf_changed, %{markdown: "hi"}}, socket())
    end

    test "continues unrelated handle_info messages" do
      assert {:cont, %Phoenix.LiveView.Socket{}} =
               Embed.__forward_leaf__({:something_else, %{}}, socket())
    end
  end

  # The component id is the host's and may hold a ":" ("comments:post:42").
  # Parsed from the left, such an id made every editor event `:pass`, so the
  # rich-text composer's content never reached the component and Post posted
  # nothing. `forward_leaf_event/2` enqueues a `send_update` to the test
  # process, which shows the id the update is addressed to.
  describe "CommentsComponent.forward_leaf_event/2 editor ids" do
    alias PhoenixKitComments.Web.CommentsComponent

    for {editor_id, component_id, kind} <- [
          {"pk-comments:thread-1:draft:top", "thread-1", :draft},
          {"pk-comments:comments:post:42:draft:bottom", "comments:post:42", :draft},
          {"pk-comments:a:b:reply:0190", "a:b", :reply},
          {"pk-comments:a:b:edit:0190", "a:b", :edit}
        ] do
      test "routes #{editor_id} to #{inspect(component_id)} as #{kind}" do
        msg = {:leaf_changed, %{editor_id: unquote(editor_id), markdown: "hi"}}
        assert {:noreply, _socket} = CommentsComponent.forward_leaf_event(msg, socket())

        assert_received {:phoenix, :send_update,
                         {{CommentsComponent, unquote(component_id)},
                          %{leaf_content_changed: %{kind: unquote(kind), content: "hi"}}}}
      end
    end

    for editor_id <- [
          "my-app:body-editor",
          "pk-comments:",
          "pk-comments:draft:top",
          "pk-comments::draft:top",
          "pk-comments:thread-1:other:x",
          "pk-comments:thread-1:draft:"
        ] do
      test "passes #{inspect(editor_id)} through" do
        msg = {:leaf_changed, %{editor_id: unquote(editor_id), markdown: "hi"}}
        assert CommentsComponent.forward_leaf_event(msg, socket()) == :pass
        refute_received {:phoenix, :send_update, _}
      end
    end
  end
end
