defmodule PhoenixKitComments.MetadataTest do
  @moduledoc """
  The metadata read/write paths added in PR #34, so hosts that key comments
  on something other than a uuid don't drop to schemaless SQL against this
  package's table.

  PR #34's review could only cover the empty-match guard — the rest needs a
  real database, and the review environment had none. These are the query
  paths it named: the `->>` filter, the atomic `COALESCE(?, '{}') || ?`
  writes, and the bulk retarget.
  """
  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKitComments.Comment

  setup do
    %{user: user_fixture()}
  end

  describe "list_comments/3 with :metadata" do
    test "filters to the comments carrying every key asked for", %{user: user} do
      resource = Ecto.UUID.generate()

      a =
        comment_fixture(user, %{
          resource_uuid: resource,
          metadata: %{"slug" => "intro", "kind" => "note"}
        })

      _b =
        comment_fixture(user, %{
          resource_uuid: resource,
          metadata: %{"slug" => "outro", "kind" => "note"}
        })

      # Every pair is ANDed, so two keys narrow rather than widen.
      assert [found] =
               PhoenixKitComments.list_comments("test_resource", resource,
                 metadata: %{"slug" => "intro"}
               )

      assert found.uuid == a.uuid

      assert [^found] =
               PhoenixKitComments.list_comments("test_resource", resource,
                 metadata: %{"slug" => "intro", "kind" => "note"}
               )

      assert PhoenixKitComments.list_comments("test_resource", resource,
               metadata: %{"slug" => "intro", "kind" => "other"}
             ) == []
    end

    test "compares as text, so 1 and \"1\" are the same question", %{user: user} do
      resource = Ecto.UUID.generate()
      comment_fixture(user, %{resource_uuid: resource, metadata: %{"page" => 1}})

      # The `->>` operator is deliberate: a caller filtering on a slug should
      # not have to know whether the host stored the value as a JSON number
      # or a string. Containment (`@>`) would make these two different.
      for value <- [1, "1"] do
        assert [_] =
                 PhoenixKitComments.list_comments("test_resource", resource,
                   metadata: %{"page" => value}
                 )
      end
    end

    test "an empty or absent match is not a filter", %{user: user} do
      resource = Ecto.UUID.generate()
      comment_fixture(user, %{resource_uuid: resource, metadata: %{"slug" => "a"}})
      comment_fixture(user, %{resource_uuid: resource})

      assert length(PhoenixKitComments.list_comments("test_resource", resource)) == 2

      assert length(PhoenixKitComments.list_comments("test_resource", resource, metadata: %{})) ==
               2
    end
  end

  describe "update_metadata/2" do
    test "merges into what is there, leaving other keys alone", %{user: user} do
      comment = comment_fixture(user, %{metadata: %{"slug" => "old", "keep" => "me"}})

      assert {:ok, updated} =
               PhoenixKitComments.update_metadata(comment.uuid, %{"slug" => "new"})

      assert host_keys(updated) == %{"slug" => "new", "keep" => "me"}
      assert host_keys(Repo.get!(Comment, comment.uuid)) == %{"slug" => "new", "keep" => "me"}
    end

    test "a null metadata column still takes the patch", %{user: user} do
      # The COALESCE is load-bearing: `NULL || jsonb` is NULL in Postgres, so
      # without it this would report success and store nothing.
      comment = comment_fixture(user)

      {1, _} =
        Repo.update_all(from(c in Comment, where: c.uuid == ^comment.uuid), set: [metadata: nil])

      assert {:ok, updated} = PhoenixKitComments.update_metadata(comment.uuid, %{"slug" => "x"})
      assert updated.metadata == %{"slug" => "x"}
    end

    test "accepts a struct as well as a uuid, and reports a missing row", %{user: user} do
      comment = comment_fixture(user)

      assert {:ok, _} = PhoenixKitComments.update_metadata(comment, %{"via" => "struct"})

      assert {:error, :not_found} =
               PhoenixKitComments.update_metadata(Ecto.UUID.generate(), %{"slug" => "x"})
    end
  end

  describe "merge_metadata/3" do
    test "retargets every matching comment and returns the count", %{user: user} do
      for _ <- 1..2, do: comment_fixture(user, %{metadata: %{"owner" => "old"}})
      untouched = comment_fixture(user, %{metadata: %{"owner" => "other"}})

      assert PhoenixKitComments.merge_metadata(
               "test_resource",
               %{"owner" => "old"},
               %{"owner" => "new"}
             ) == 2

      assert host_keys(Repo.get!(Comment, untouched.uuid)) == %{"owner" => "other"}
    end

    test "is scoped to the resource type", %{user: user} do
      mine = comment_fixture(user, %{metadata: %{"owner" => "old"}})

      theirs =
        comment_fixture(user, %{resource_type: "other_resource", metadata: %{"owner" => "old"}})

      assert PhoenixKitComments.merge_metadata(
               "test_resource",
               %{"owner" => "old"},
               %{"owner" => "new"}
             ) == 1

      assert host_keys(Repo.get!(Comment, mine.uuid)) == %{"owner" => "new"}
      assert host_keys(Repo.get!(Comment, theirs.uuid)) == %{"owner" => "old"}
    end

    test "refuses an empty match rather than rewriting the whole type", %{user: user} do
      comment = comment_fixture(user, %{metadata: %{"owner" => "old"}})

      assert_raise ArgumentError, ~r/non-empty match/, fn ->
        PhoenixKitComments.merge_metadata("test_resource", %{}, %{"owner" => "new"})
      end

      assert host_keys(Repo.get!(Comment, comment.uuid)) == %{"owner" => "old"}
    end
  end

  # The comment's own mark (`Comment.published_key/0`, whether it was ever
  # published) rides in the same map; these tests are about the host's keys.
  defp host_keys(comment), do: Map.delete(comment.metadata, Comment.published_key())
end
