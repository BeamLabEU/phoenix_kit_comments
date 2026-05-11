defmodule PhoenixKitCommentsTest do
  use ExUnit.Case

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitComments.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitComments.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns correct string" do
      key = PhoenixKitComments.module_key()
      assert is_binary(key)
      assert key == "comments"
    end

    test "module_name/0 returns display name" do
      name = PhoenixKitComments.module_name()
      assert is_binary(name)
      assert name == "Comments"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitComments.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitComments, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitComments, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitComments.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitComments.permission_metadata()
      assert meta.key == PhoenixKitComments.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitComments.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = PhoenixKitComments.admin_tabs()
      assert is_list(tabs)
      assert tabs != []
    end

    test "main tab has required fields" do
      [tab | _] = PhoenixKitComments.admin_tabs()
      assert tab.id == :admin_comments
      assert tab.label == "Comments"
      assert is_binary(tab.path)
      assert tab.level == :admin
      assert tab.permission == PhoenixKitComments.module_key()
      assert tab.group == :admin_modules
    end

    test "main tab has live_view for route generation" do
      [tab | _] = PhoenixKitComments.admin_tabs()
      assert {PhoenixKitComments.Web.Index, :index} = tab.live_view
    end

    test "all tabs have live_view tuples" do
      for tab <- PhoenixKitComments.admin_tabs() do
        assert {_module, _action} = tab.live_view,
               "Tab #{tab.id} is missing live_view tuple"
      end
    end
  end

  describe "settings_tabs/0" do
    test "returns a list with settings tab" do
      tabs = PhoenixKitComments.settings_tabs()
      assert is_list(tabs)
      assert length(tabs) == 1
    end

    test "settings tab has live_view for route generation" do
      [tab] = PhoenixKitComments.settings_tabs()
      assert {PhoenixKitComments.Web.Settings, :settings} = tab.live_view
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = PhoenixKitComments.version()
      assert is_binary(version)
      assert version == "0.1.5"
    end

    test "stays in sync with mix.exs @version" do
      assert PhoenixKitComments.version() ==
               Mix.Project.config()[:version]
    end
  end

  describe "optional callbacks have defaults" do
    test "get_config/0 is exported" do
      assert function_exported?(PhoenixKitComments, :get_config, 0)
    end

    test "css_sources/0 returns list with app name" do
      assert PhoenixKitComments.css_sources() == [:phoenix_kit_comments]
    end
  end

  describe "attachment configuration" do
    test "attachments_enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitComments.attachments_enabled?())
    end

    test "get_max_attachments/0 returns a positive integer" do
      n = PhoenixKitComments.get_max_attachments()
      assert is_integer(n)
      assert n > 0
    end

    test "get_max_attachment_size_mb/0 returns a positive integer" do
      n = PhoenixKitComments.get_max_attachment_size_mb()
      assert is_integer(n)
      assert n > 0
    end
  end

  describe "Comment.changeset content/media validation" do
    alias PhoenixKitComments.Comment

    @base_attrs %{
      resource_type: "post",
      resource_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
      user_uuid: "018e3c4a-1234-5678-abcd-ef1234567890"
    }

    test "rejects fully blank comment (no content, no giphy, no attachments)" do
      cs = Comment.changeset(%Comment{}, @base_attrs)
      refute cs.valid?
      assert {"can't be blank without a GIF or attachment", _} = cs.errors[:content]
    end

    test "accepts comment with non-empty content" do
      cs = Comment.changeset(%Comment{}, Map.put(@base_attrs, :content, "hi"))
      assert cs.valid?
    end

    test "accepts comment with a giphy attachment in metadata" do
      attrs =
        Map.put(@base_attrs, :metadata, %{
          "giphy" => %{"url" => "https://media.giphy.com/foo.gif"}
        })

      cs = Comment.changeset(%Comment{}, attrs)
      assert cs.valid?
    end

    test "accepts blank content when has_attachments? virtual is true" do
      cs = Comment.changeset(%Comment{}, Map.put(@base_attrs, :has_attachments?, true))
      assert cs.valid?
    end

    test "rejects when giphy value is a non-renderable shape" do
      attrs = Map.put(@base_attrs, :metadata, %{"giphy" => %{"id" => "no-url"}})
      cs = Comment.changeset(%Comment{}, attrs)
      refute cs.valid?
    end
  end

  describe "CommentMedia.changeset" do
    alias PhoenixKitComments.CommentMedia

    @attrs %{
      comment_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
      file_uuid: "018e3c4a-1234-5678-abcd-ef1234567890",
      position: 1
    }

    test "requires comment_uuid, file_uuid, position" do
      cs = CommentMedia.changeset(%CommentMedia{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :comment_uuid)
      assert Keyword.has_key?(cs.errors, :file_uuid)
      assert Keyword.has_key?(cs.errors, :position)
    end

    test "rejects position <= 0" do
      cs = CommentMedia.changeset(%CommentMedia{}, Map.put(@attrs, :position, 0))
      refute cs.valid?
      {msg, _opts} = cs.errors[:position]
      assert msg =~ "must be greater than"
    end

    test "accepts valid attrs" do
      cs = CommentMedia.changeset(%CommentMedia{}, @attrs)
      assert cs.valid?
    end
  end
end
