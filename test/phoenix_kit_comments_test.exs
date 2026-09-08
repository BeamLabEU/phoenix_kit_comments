defmodule PhoenixKitCommentsTest do
  use ExUnit.Case

  # `function_exported?/3` answers FALSE for a module that is merely not
  # loaded, not only for one that lacks the function. Nothing forces
  # PhoenixKitComments into memory before the five callback assertions here,
  # so under a random seed they failed intermittently and never when the test
  # ran alone -- the shape that reads as flaky infrastructure and gets re-run
  # instead of fixed. Loading it once up front makes them deterministic.
  setup_all do
    Code.ensure_loaded!(PhoenixKitComments)
    :ok
  end

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
      assert [%PhoenixKit.Dashboard.Tab{} | _] = PhoenixKitComments.admin_tabs()
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
      assert version =~ ~r/^\d+\.\d+\.\d+/
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

  describe "rich-text editor configuration" do
    test "rich_text_enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitComments.rich_text_enabled?())
    end
  end

  describe "editor mode normalization" do
    # Leaf's `:mode` clauses have no catch-all, so whatever the core
    # setting hands back must be coerced to one of its four atoms before
    # it reaches the editor. Keep this list in sync with Leaf's
    # `attr(:mode, :atom, values: [...])`.
    alias PhoenixKitComments.Web.CommentsComponent

    test "passes through every mode Leaf accepts" do
      for mode <- [:visual, :hybrid, :markdown, :html] do
        assert CommentsComponent.__normalize_editor_mode__(mode) == mode
      end
    end

    test "converts the string form settings round-trip through" do
      for mode <- [:visual, :hybrid, :markdown, :html] do
        assert CommentsComponent.__normalize_editor_mode__(to_string(mode)) == mode
      end
    end

    test "falls back to :hybrid for anything Leaf would not match" do
      for value <- [nil, "", "wysiwyg", :wysiwyg, 42, %{}] do
        assert CommentsComponent.__normalize_editor_mode__(value) == :hybrid
      end
    end
  end

  describe "batch count_comments/3" do
    test "empty uuid list returns an empty map" do
      assert PhoenixKitComments.count_comments("post", []) == %{}
    end

    test "returns a uuid => count map with a zero entry for every requested uuid" do
      # No repo is configured in these unit tests, so the grouped query
      # falls through to the rescue clause — which still must return the
      # zero-filled, deduped shape callers rely on for uniform rendering.
      uuid_a = "018e3c4a-9f6b-7890-abcd-ef1234567890"
      uuid_b = "018e3c4a-1234-5678-abcd-ef1234567890"

      assert PhoenixKitComments.count_comments("post", [uuid_a, uuid_b, uuid_a]) ==
               %{uuid_a => 0, uuid_b => 0}
    end
  end

  describe "live updates (PubSub)" do
    test "topic/2 builds a per-resource topic string" do
      assert PhoenixKitComments.topic("order", "abc-123") ==
               "phoenix_kit_comments:order:abc-123"
    end

    test "subscribe/2 and unsubscribe/2 are exported" do
      assert function_exported?(PhoenixKitComments, :subscribe, 2)
      assert function_exported?(PhoenixKitComments, :unsubscribe, 2)
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

    test "accepts blank content when has_media: true is passed in opts" do
      cs = Comment.changeset(%Comment{}, @base_attrs, has_media: true)
      assert cs.valid?
    end

    test "ignores has_attachments? in attrs (no longer a public cast field)" do
      # Regression: `:has_attachments?` was previously castable, which let
      # any caller of `update_comment/2` claim media presence without
      # actually having any. The virtual field is gone — passing it via
      # attrs should be ignored and the blank-content rule still fires.
      cs = Comment.changeset(%Comment{}, Map.put(@base_attrs, :has_attachments?, true))
      refute cs.valid?
      assert {"can't be blank without a GIF or attachment", _} = cs.errors[:content]
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

  describe "merge_metadata/3 guard" do
    # The bulk rename is the one call here that can rewrite a whole resource
    # type in a single statement, and an empty match is what a typo looks
    # like. Refused before it reaches the database rather than after.
    test "refuses an empty match" do
      assert_raise ArgumentError, ~r/non-empty match/, fn ->
        PhoenixKitComments.merge_metadata("chapter", %{}, %{"slug" => "new"})
      end
    end
  end
end
