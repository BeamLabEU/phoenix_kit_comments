defmodule PhoenixKitComments.Integration.MentionChipsTest do
  @moduledoc """
  A posted comment shows an @ mention of a person as a chip, their face and
  name (the boss, 2026-11-18: "a user thing with like their icon and their
  name"), built on the server after the sanitiser, so nothing a writer typed
  reaches the page unescaped.
  """

  use PhoenixKitComments.LiveCase, async: false

  import PhoenixKitComments.DataCase, only: [user_fixture: 0, user_fixture: 1, comment_fixture: 2]

  defmodule RecordHandler do
    def visible_resource_uuids(uuids, _opts), do: uuids

    def resolve_comment_resources(uuids),
      do: Map.new(uuids, &{&1, %{title: "Workshop", path: "/workshop"}})
  end

  setup do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("mentions_enabled", true)
    PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")

    viewer = user_fixture()
    anna = user_fixture(%{first_name: "Anna", last_name: "Kask"})
    %{viewer: viewer, anna: anna, r: Ecto.UUID.generate()}
  end

  defp thread(conn, viewer, r) do
    {:ok, view, _html} =
      live(put_test_scope(conn, fake_scope(user: viewer)), "/en/test/thread/#{r}")

    view |> element("#first-thread") |> render()
  end

  test "a person's mention is a chip with their letters, inside the markdown around it",
       %{conn: conn, viewer: viewer, anna: anna, r: r} do
    comment_fixture(viewer, %{
      resource_type: "test_resource",
      resource_uuid: r,
      content: "**Ping** @[user:#{anna.uuid}|Anna Kask] about the walls"
    })

    html = thread(conn, viewer, r)

    assert html =~ ~s(data-mention-user="#{anna.uuid}")
    assert html =~ "AK"
    assert html =~ "Anna Kask"
    assert html =~ "<strong>Ping</strong>"
    refute html =~ "PKCHIP"
    refute html =~ "@[user:"

    # No block element inside the chip: a <div> there closes the paragraph
    # and puts the chip on a line of its own.
    [_, chip] = Regex.run(~r/data-mention-user="[^"]*"(.*?)Anna Kask/s, html)
    assert chip =~ "AK"
    refute chip =~ "<div"
  end

  test "the resolved display name is escaped inside the chip",
       %{conn: conn, viewer: viewer, r: r} do
    anna = user_fixture(%{first_name: "<display-name>", last_name: "Kask"})

    comment_fixture(viewer, %{
      resource_type: "test_resource",
      resource_uuid: r,
      content: "@[user:#{anna.uuid}|<img src=x onerror=alert(1)>] <script>alert(2)</script>"
    })

    html = thread(conn, viewer, r)

    assert html =~ ~s(data-mention-user="#{anna.uuid}")
    assert html =~ "&lt;display-name&gt; Kask"
    refute html =~ "<display-name>"
    refute html =~ "<img src=x"
    refute html =~ "<script>alert(2)"
  end

  test "text that merely looks like a placeholder stays text", %{
    conn: conn,
    viewer: viewer,
    anna: anna,
    r: r
  } do
    comment_fixture(viewer, %{
      resource_type: "test_resource",
      resource_uuid: r,
      content: "PKCHIPAAAAAAAAAAX0X stays @[user:#{anna.uuid}|Anna Kask]"
    })

    assert thread(conn, viewer, r) =~ "PKCHIPAAAAAAAAAAX0X stays"
  end

  describe "a mention where a chip cannot go (codex, 2026-11-19)" do
    setup %{anna: anna} do
      %{m: "@[user:#{anna.uuid}|Anna Kask]"}
    end

    defp body(conn, viewer, r, content) do
      comment_fixture(viewer, %{
        resource_type: "test_resource",
        resource_uuid: r,
        content: content
      })

      thread(conn, viewer, r)
    end

    test "in a link's address or title it is the plain name, the attribute intact",
         %{conn: conn, viewer: viewer, r: r, m: m} do
      html = body(conn, viewer, r, ~s{[open](/help "#{m}") and [two](/people/#{m})})

      assert html =~ ~s(title="@Anna Kask")
      refute html =~ ~r/title="[^"]*</
      refute html =~ ~r/href="[^"]*</
      refute html =~ "PKCHIP"
    end

    test "in a code span, a link's text or an autolink it is the plain name",
         %{conn: conn, viewer: viewer, r: r, m: m} do
      html =
        body(
          conn,
          viewer,
          r,
          "`#{m}` and [before #{m} after](/help) and <https://example.com/#{m}>"
        )

      refute html =~ "data-mention-user"
      refute html =~ "PKCHIP"
      assert html =~ "<code>@Anna Kask</code>"
      assert html =~ ~r{<a [^>]*href="/help"[^>]*>before @Anna Kask after</a>}
    end

    test "a stored avatar appears inline in the chip", %{conn: conn, viewer: viewer, r: r} do
      file = Ecto.UUID.generate()
      person = user_fixture(%{custom_fields: %{"avatar_file_uuid" => file}})
      html = body(conn, viewer, r, "@[user:#{person.uuid}|A]")
      assert html =~ ~s(data-mention-user="#{person.uuid}")
      assert html =~ "/file/#{file}/"
    end

    test "a different resource type with an account's uuid keeps its own rendering",
         %{conn: conn, viewer: viewer, anna: anna, r: r} do
      previous = Application.fetch_env(:phoenix_kit, :comment_resource_handlers)

      Application.put_env(:phoenix_kit, :comment_resource_handlers, %{"workshop" => RecordHandler})

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :comment_resource_handlers, value)
          :error -> Application.delete_env(:phoenix_kit, :comment_resource_handlers)
        end
      end)

      html = body(conn, viewer, r, "@[workshop:#{anna.uuid}|Workshop]")
      assert html =~ "Workshop"
      refute html =~ "data-mention-user"
    end

    test "an escaped mention stays literal alongside a real chip",
         %{conn: conn, viewer: viewer, r: r, m: m} do
      html = body(conn, viewer, r, "#{m} and \\#{m}")
      assert html =~ "data-mention-user"
      assert html =~ m
    end

    test "a mention in a URL is encoded as one value",
         %{conn: conn, viewer: viewer, r: r} do
      person = user_fixture(%{first_name: "Ann", last_name: "A&B"})
      html = body(conn, viewer, r, "[find](/search?q=@[user:#{person.uuid}|Ann])")
      assert html =~ ~s(href="/search?q=%40Ann%20A%26B")
    end

    test "withholding titles removes the account chip and link on an open thread",
         %{conn: conn, viewer: viewer, anna: anna, r: r, m: m} do
      comment_fixture(viewer, %{resource_type: "test_resource", resource_uuid: r, content: m})

      {:ok, view, _} =
        live(put_test_scope(conn, fake_scope(user: viewer)), "/en/test/thread/#{r}")

      assert has_element?(view, "[data-mention-user]")

      Phoenix.LiveView.send_update(view.pid, PhoenixKitComments.Web.CommentsComponent,
        id: "test-thread",
        withhold_mention_titles: true
      )

      html = render(view)
      assert html =~ "Anna Kask"
      refute html =~ anna.uuid
      refute html =~ "data-mention-user"
    end

    test "a reference link whose label is a mention still links",
         %{conn: conn, viewer: viewer, r: r, m: m} do
      html = body(conn, viewer, r, "[open][#{m}]\n\n[#{m}]: /help")

      assert html =~ ~r{<a [^>]*href="/help"}
      refute html =~ "PKCHIP"
    end
  end
end
