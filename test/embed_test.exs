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
end
