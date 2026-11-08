defmodule PhoenixKitComments.Integration.ModuleConfigTest do
  @moduledoc """
  The module switch, the settings readers and the cross-session plumbing,
  against real rows. The unit tests next door can only reach these
  functions' rescue paths (no sandbox ownership there), so on their own they
  proved a reader returns an integer, not that it returns the RIGHT one.
  """

  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKit.Settings

  defp put(key, value), do: {:ok, _} = Settings.update_setting_with_module(key, value, "comments")

  test "enable_system/0 and disable_system/0 flip enabled?/0" do
    PhoenixKitComments.enable_system()
    assert PhoenixKitComments.enabled?()

    PhoenixKitComments.disable_system()
    refute PhoenixKitComments.enabled?()
  end

  describe "numeric settings" do
    test "a stored value is read" do
      put("comments_max_depth", "3")
      put("comments_max_length", "500")
      put("comments_max_attachments", "2")

      assert PhoenixKitComments.get_max_depth() == 3
      assert PhoenixKitComments.get_max_length() == 500
      assert PhoenixKitComments.get_max_attachments() == 2
    end

    # A stored "0" made `validate_depth/1` refuse every comment and the
    # length check refuse every body; junk is no better.
    # (Not "" or " ": core refuses to store an empty value for a key with no
    # row, so a blank one is never read back.)
    for value <- ["0", "-4", "lots", "x10"] do
      test "#{inspect(value)} falls back to the default" do
        put("comments_max_depth", unquote(value))
        put("comments_max_length", unquote(value))
        put("comments_max_attachments", unquote(value))

        assert PhoenixKitComments.get_max_depth() == 10
        assert PhoenixKitComments.get_max_length() == 10_000
        assert PhoenixKitComments.get_max_attachments() == 4
      end
    end

    test "a stored 0 does not block commenting" do
      put("comments_max_depth", "0")
      put("comments_max_length", "0")
      author = user_fixture()

      assert {:ok, _} =
               PhoenixKitComments.create_comment("post", Ecto.UUID.generate(), author.uuid, %{
                 content: "still possible"
               })
    end

    test "the attachment size is clamped by the global upload cap" do
      put("comments_attachment_max_size_mb", "50")
      put("storage_max_upload_size_mb", "8")
      assert PhoenixKitComments.get_max_attachment_size_mb() == 8

      put("storage_max_upload_size_mb", "500")
      assert PhoenixKitComments.get_max_attachment_size_mb() == 50
    end
  end

  describe "Giphy settings" do
    test "the rating is one Giphy knows, whatever is stored" do
      put("comments_giphy_rating", "pg-13")
      assert PhoenixKitComments.get_giphy_rating() == "pg-13"

      put("comments_giphy_rating", "nc-17&api_key=x")
      assert PhoenixKitComments.get_giphy_rating() == "g"
    end

    test "the picker needs the toggle AND a key" do
      # No key stored yet.
      put("comments_giphy_enabled", "true")
      refute PhoenixKitComments.giphy_enabled?()

      put("comments_giphy_api_key", "key")
      assert PhoenixKitComments.giphy_enabled?()

      put("comments_giphy_enabled", "false")
      refute PhoenixKitComments.giphy_enabled?()
      assert {:error, :giphy_disabled} = PhoenixKitComments.search_giphy("cats")
    end
  end

  test "count_comments/3 with a list counts every requested resource in one map" do
    author = user_fixture()
    busy = Ecto.UUID.generate()
    quiet = Ecto.UUID.generate()

    for _ <- 1..2, do: comment_fixture(author, %{resource_type: "post", resource_uuid: busy})

    assert PhoenixKitComments.count_comments("post", [busy, quiet, busy]) ==
             %{busy => 2, quiet => 0}
  end

  test "get_config/0 reports the module's counts" do
    author = user_fixture()
    comment_fixture(author)
    comment_fixture(author, %{status: "pending"})

    assert %{total_comments: 2, published_comments: 1, pending_comments: 1} =
             PhoenixKitComments.get_config()
  end

  test "subscribe/2 hears the resource's changes until unsubscribe/2" do
    author = user_fixture()
    resource = Ecto.UUID.generate()
    :ok = PhoenixKitComments.subscribe("post", resource)

    comment = comment_fixture(author, %{resource_type: "post", resource_uuid: resource})
    assert_receive {:comments_updated, %{action: :created, resource_uuid: ^resource}}

    :ok = PhoenixKitComments.unsubscribe("post", resource)
    {:ok, _} = PhoenixKitComments.delete_comment(comment)
    refute_receive {:comments_updated, _}, 100
  end
end
