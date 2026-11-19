defmodule PhoenixKitComments.Integration.MentionChipsTest do
  @moduledoc """
  A posted comment shows an @ mention of a person as a chip, their face and
  name (the boss, 2026-11-18: "a user thing with like their icon and their
  name"), built on the server after the sanitiser, so nothing a writer typed
  reaches the page unescaped.
  """

  use PhoenixKitComments.LiveCase, async: false

  import PhoenixKitComments.DataCase, only: [user_fixture: 0, user_fixture: 1, comment_fixture: 2]

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

  test "a hostile label is escaped, in the chip and the text around it",
       %{conn: conn, viewer: viewer, anna: anna, r: r} do
    comment_fixture(viewer, %{
      resource_type: "test_resource",
      resource_uuid: r,
      content: "@[user:#{anna.uuid}|<img src=x onerror=alert(1)>] <script>alert(2)</script>"
    })

    html = thread(conn, viewer, r)

    assert html =~ ~s(data-mention-user="#{anna.uuid}")
    refute html =~ "<img src=x"
    refute html =~ "<script>alert(2)"
  end

  test "text that merely looks like a placeholder stays text", %{conn: conn, viewer: viewer, r: r} do
    comment_fixture(viewer, %{
      resource_type: "test_resource",
      resource_uuid: r,
      content: "PKCHIPAAAAX0X stays"
    })

    assert thread(conn, viewer, r) =~ "PKCHIPAAAAX0X stays"
  end
end
