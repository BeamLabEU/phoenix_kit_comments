defmodule PhoenixKitComments.ModerationPermissionsTest do
  @moduledoc """
  The context half of the permission split: the one-time backfill that
  carries existing roles across it, and the moderation rule's SQL at a size a
  busy site produces.
  """
  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKit.Users.{Permissions, Roles}

  @moderate_all "comments.moderate_all"
  @settings "comments.settings"

  defp role!(name) do
    {:ok, role} = Roles.create_role(%{name: "#{name} #{System.unique_integer([:positive])}"})
    role
  end

  defp keys(role), do: Permissions.get_permissions_for_role(role.uuid)

  describe "migrate_legacy/0" do
    @tag :capture_log
    test "grants both sub-keys once to roles holding the base key, and sets the flags" do
      moderator = role!("Moderator")
      bystander = role!("Bystander")
      {:ok, _} = Permissions.grant_permission(moderator.uuid, "comments", nil)

      assert PhoenixKitComments.migrate_legacy() == :ok

      assert @moderate_all in keys(moderator)
      assert @settings in keys(moderator)
      refute "comments" in keys(bystander)
      refute @moderate_all in keys(bystander)

      assert PhoenixKit.Settings.get_setting("comments_moderate_all_backfilled") == "true"
      assert PhoenixKit.Settings.get_setting("comments_settings_backfilled") == "true"
    end

    @tag :capture_log
    test "a role granted the base key after the backfill gets the narrow meaning" do
      assert PhoenixKitComments.migrate_legacy() == :ok

      later = role!("Later")
      {:ok, _} = Permissions.grant_permission(later.uuid, "comments", nil)

      assert PhoenixKitComments.migrate_legacy() == :ok

      assert "comments" in keys(later)
      refute @moderate_all in keys(later)
      refute @settings in keys(later)
    end

    @tag :capture_log
    test "a revoked sub-key is not handed back on the next boot" do
      moderator = role!("Moderator")
      {:ok, _} = Permissions.grant_permission(moderator.uuid, "comments", nil)
      assert PhoenixKitComments.migrate_legacy() == :ok

      :ok = Permissions.revoke_permission(moderator.uuid, @moderate_all)
      assert PhoenixKitComments.migrate_legacy() == :ok

      refute @moderate_all in keys(moderator)
    end

    @tag :capture_log
    test "a failed grant leaves the flag unset so the next boot retries" do
      moderator = role!("Moderator")
      {:ok, _} = Permissions.grant_permission(moderator.uuid, "comments", nil)

      failing = fn _role, _key, _by -> {:error, :boom} end

      assert {:error, _} =
               PhoenixKitComments.backfill_sub_permission(
                 @moderate_all,
                 "comments_moderate_all_backfilled",
                 failing
               )

      refute PhoenixKit.Settings.get_setting("comments_moderate_all_backfilled") == "true"
      refute @moderate_all in keys(moderator)

      # The retry, with grants working again, completes.
      assert PhoenixKitComments.migrate_legacy() == :ok
      assert @moderate_all in keys(moderator)
    end
  end

  describe "the moderation rule at scale" do
    defmodule HugeHandler do
      @moduledoc false
      def moderatable_resources(_type, _scope),
        do: Application.get_env(:phoenix_kit_comments, :test_huge_answer, [])
    end

    setup do
      previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)
      Application.put_env(:phoenix_kit, :comment_resource_handlers, %{"huge" => HugeHandler})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
          else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)

        Application.delete_env(:phoenix_kit_comments, :test_huge_answer)
      end)

      PhoenixKit.Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
      :ok
    end

    test "70,000 managed uuids bind as one parameter and still filter" do
      user = user_fixture()
      target = Ecto.UUID.generate()
      mine = comment_fixture(user, %{resource_type: "huge", resource_uuid: target})
      _other = comment_fixture(user, %{resource_type: "huge"})

      # Over Postgres's 65,535-parameter ceiling: an expanded `IN ($1, …)`
      # fails to prepare. Bound as one array it is an ordinary query.
      answer = [target | Enum.map(1..70_000, fn _ -> Ecto.UUID.generate() end)]
      Application.put_env(:phoenix_kit_comments, :test_huge_answer, answer)

      scope = %PhoenixKit.Users.Auth.Scope{
        user: user,
        authenticated?: true,
        cached_roles: ["Editor"],
        cached_permissions: MapSet.new(["comments"])
      }

      rule = PhoenixKitComments.moderation_scope(scope)
      assert map_size(rule.uuids) == 1

      result = PhoenixKitComments.list_all_comments(moderation: rule)
      assert Enum.map(result.comments, & &1.uuid) == [mine.uuid]
      assert result.total == 1
      assert PhoenixKitComments.comment_stats(rule).total == 1
      assert PhoenixKitComments.list_resource_types(rule) == ["huge"]
      assert PhoenixKitComments.get_comment_for_moderation(mine.uuid, rule)
      assert PhoenixKitComments.bulk_hide([mine.uuid], moderation: rule) == {1, 0}
    end
  end

  describe "moderation_allows?/3" do
    test "fails closed on anything that is not a rule" do
      refute PhoenixKitComments.moderation_allows?(nil, "post", Ecto.UUID.generate())
      refute PhoenixKitComments.moderation_allows?(%{all_types: [], uuids: %{}}, "post", "x")
      assert PhoenixKitComments.moderation_allows?(:all, "anything", nil)

      uuid = Ecto.UUID.generate()
      rule = %{all_types: ["crm"], uuids: %{"project" => [uuid]}}
      assert PhoenixKitComments.moderation_allows?(rule, "crm", Ecto.UUID.generate())
      assert PhoenixKitComments.moderation_allows?(rule, "project", uuid)
      refute PhoenixKitComments.moderation_allows?(rule, "project", Ecto.UUID.generate())
      refute PhoenixKitComments.moderation_allows?(rule, "task", uuid)
    end

    test "a scope without the base key moderates nothing" do
      assert PhoenixKitComments.moderation_scope(nil) == %{all_types: [], uuids: %{}}
    end
  end
end
