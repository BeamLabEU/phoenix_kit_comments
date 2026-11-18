defmodule PhoenixKitComments.Web.LeafMentionsTest do
  @moduledoc """
  `@` / `#` mentions in the rich (Leaf) editor.

  With a Leaf that has `notify`, the thread's editors report to the
  component itself: what is typed reaches the thread with no help from the
  host, and the popup's questions are answered with core's finished mention
  tokens. Leaf's messages are delivered the way `notify` delivers them —
  `send_update(CommentsComponent, id: …, leaf: message)` — so these tests do
  not depend on which Leaf the lock resolves.
  """
  use PhoenixKitComments.LiveCase

  import Ecto.Query

  alias PhoenixKit.Mentions.Mention
  alias PhoenixKit.Users.Roles
  alias PhoenixKitComments.Test.Repo
  alias PhoenixKitComments.Web.CommentsComponent

  setup do
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_rich_text", true, "comments")
    Application.put_env(:phoenix_kit_comments, :leaf_notify, true)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_comments, :leaf_notify)
      PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
    end)

    user = user_fixture()
    %{user: user, scope: fake_scope(user: user), resource_uuid: Ecto.UUID.generate()}
  end

  defp open(conn, scope, resource_uuid) do
    {:ok, view, _} = conn |> put_test_scope(scope) |> live("/en/test/thread/#{resource_uuid}")
    html = view |> element("button[phx-click='open_composer']") |> render_click()
    [_, editor_id] = Regex.run(~r{id="(pk-comments:test-thread:draft:[^"]+)"}, html)
    {view, html, editor_id}
  end

  defp leaf_has_mentions? do
    case Leaf.__components__()[:leaf_editor] do
      %{attrs: attrs} -> Enum.any?(attrs, &(&1.name == :mentions))
      _ -> false
    end
  end

  defp leaf(view, message) do
    Phoenix.LiveView.send_update(view.pid, CommentsComponent, id: "test-thread", leaf: message)
    render(view)
  end

  defp suggest(view, editor_id, trigger, query) do
    leaf(view, {:leaf_suggest, %{editor_id: editor_id, trigger: trigger, query: query, seq: 7}})
    assert_push_event(view, "leaf-suggestions:" <> ^editor_id, %{seq: 7, results: results})
    results
  end

  test "the rich editor offers @ and #", %{conn: conn, scope: scope, resource_uuid: r} do
    {_view, html, _id} = open(conn, scope, r)
    assert html =~ "data-leaf-suggestions"
    assert html =~ "Type @ to mention someone"
    # A Leaf with mention chips shows a picked mention as "@Name" (ALEX-75);
    # one without the attribute ignores it.
    assert html =~ ~s(data-mentions="true") or not leaf_has_mentions?()
  end

  test "what is typed reaches the thread without the host forwarding it", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    {view, _html, editor_id} = open(conn, scope, r)

    leaf(
      view,
      {:leaf_changed, %{editor_id: editor_id, markdown: "Straight in", html: "", dirty: true}}
    )

    view |> element("form[phx-submit='add_comment']") |> render_submit(%{})

    assert [%{content: "Straight in"}] = PhoenixKitComments.list_comments("test_resource", r)
  end

  test "@ is answered with core's token for a person", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    ada = user_fixture(%{first_name: "Ada", last_name: "Lovelace", username: "ada"})
    {:ok, _} = Roles.assign_role(ada, "Admin")

    {view, _html, editor_id} = open(conn, scope, r)
    results = suggest(view, editor_id, "@", "ada")

    assert %{value: token, label: label} = Enum.find(results, &(&1.value =~ ada.uuid))
    assert token =~ ~r/^@\[user:#{ada.uuid}\|.+\]$/
    assert label != ""
  end

  test "a picked mention posts, renders and pings", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    ada = user_fixture(%{first_name: "Ada", last_name: "Lovelace", username: "ada"})
    {:ok, _} = Roles.assign_role(ada, "Admin")

    {view, _html, editor_id} = open(conn, scope, r)
    [%{value: token} | _] = suggest(view, editor_id, "@", "ada")

    leaf(
      view,
      {:leaf_changed, %{editor_id: editor_id, markdown: "Hi #{token} ", html: "", dirty: true}}
    )

    html = view |> element("form[phx-submit='add_comment']") |> render_submit(%{})

    assert [%{content: content}] = PhoenixKitComments.list_comments("test_resource", r)
    assert content =~ token
    # Rendered as a mention, not as the raw token.
    refute html =~ "user:#{ada.uuid}|"

    # Indexed for Ada — what her ping and "mentions of me" read.
    assert Repo.exists?(
             from(m in Mention,
               where: m.target_uuid == ^ada.uuid and m.source_type == "comment"
             )
           )
  end

  # Leaf's visual mode writes the markdown back from HTML and escapes the
  # token's `[`; the mention must survive it.
  test "a mention picked in visual mode is still a mention", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    ada = user_fixture(%{first_name: "Ada", username: "ada"})
    {:ok, _} = Roles.assign_role(ada, "Admin")

    {view, _html, editor_id} = open(conn, scope, r)
    escaped = "Hi @\\[user:#{ada.uuid}|Ada]"
    leaf(view, {:leaf_changed, %{editor_id: editor_id, markdown: escaped, html: "", dirty: true}})
    view |> element("form[phx-submit='add_comment']") |> render_submit(%{})

    assert [%{content: "Hi @[user:" <> _}] = PhoenixKitComments.list_comments("test_resource", r)
  end

  test "another thread's editor is not answered, and nothing breaks", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    {view, _html, _id} = open(conn, scope, r)
    other = "pk-comments:other-thread:draft:top"
    leaf(view, {:leaf_suggest, %{editor_id: other, trigger: "@", query: "a", seq: 1}})
    refute_push_event(view, "leaf-suggestions:pk-comments:other-thread:draft:top", %{})
    assert render(view) =~ "add_comment"
  end

  test "with mentions off the popup gets an empty answer", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    PhoenixKit.Settings.update_boolean_setting("mentions_enabled", false)
    on_exit(fn -> PhoenixKit.Settings.update_boolean_setting("mentions_enabled", true) end)

    {view, html, editor_id} = open(conn, scope, r)
    refute html =~ "data-leaf-suggestions"
    assert suggest(view, editor_id, "@", "a") == []
  end

  test "Leaf's other messages are ignored", %{conn: conn, scope: scope, resource_uuid: r} do
    {view, _html, editor_id} = open(conn, scope, r)
    leaf(view, {:leaf_focus, %{editor_id: editor_id}})
    leaf(view, {:something_new, %{}})
    assert render(view) =~ "add_comment"
  end

  test "without notify, Leaf runs as before and offers no mentions", %{
    conn: conn,
    scope: scope,
    resource_uuid: r
  } do
    Application.put_env(:phoenix_kit_comments, :leaf_notify, false)
    {_view, html, _id} = open(conn, scope, r)
    refute html =~ "data-leaf-suggestions"
  end

  describe "where a mention notification takes its reader" do
    setup do
      previous = PhoenixKit.ResourceLinks.get_resource_path_templates()

      PhoenixKit.ResourceLinks.update_resource_path_templates(%{
        "test_resource" => "/things/:uuid"
      })

      on_exit(fn -> PhoenixKit.ResourceLinks.update_resource_path_templates(previous) end)
      :ok
    end

    test "to the comment itself, on its record's page", %{user: user, resource_uuid: r} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", r, user.uuid, %{"content" => "Hi"})

      assert CommentsComponent.comment_link(comment) == "/things/#{r}#pk-comment-#{comment.uuid}"
    end

    test "nowhere when the record has no page", %{user: user} do
      {:ok, comment} =
        PhoenixKitComments.create_comment("unlinked_type", Ecto.UUID.generate(), user.uuid, %{
          "content" => "Hi"
        })

      assert CommentsComponent.comment_link(comment) == nil
    end

    test "every comment carries the anchor, and the thread the hook that jumps to it", %{
      conn: conn,
      scope: scope,
      user: user,
      resource_uuid: r
    } do
      {:ok, comment} =
        PhoenixKitComments.create_comment("test_resource", r, user.uuid, %{"content" => "Hi"})

      {:ok, _view, html} = conn |> put_test_scope(scope) |> live("/en/test/thread/#{r}")
      assert html =~ ~s(id="pk-comment-#{comment.uuid}")
      assert html =~ ~s(phx-hook="PhoenixKitCommentsJumpToComment")
    end
  end
end
