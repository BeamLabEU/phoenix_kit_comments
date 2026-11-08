defmodule PhoenixKitComments.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Until this existed, `config/test.exs` configured no repo at all — so ~40
  of the module's ~57 public functions could not be exercised, and several
  unit tests were silently asserting the *rescue* path (`count_comments/3`
  returning 0 because there was no database, not because there were no
  comments). Every defect the quality sweep found lived in that gap.

  Tests using this case are tagged `:integration` and are excluded
  automatically when PostgreSQL is unavailable, so `mix test` still runs the
  unit half on a machine with no database.

      defmodule PhoenixKitComments.Integration.SomethingTest do
        use PhoenixKitComments.DataCase, async: true
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitComments.DataCase
      import PhoenixKitComments.ActivityLogAssertions

      alias PhoenixKitComments.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitComments.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  A persisted user, for comments that need a real author.

  Comments FK to `phoenix_kit_users`, so a random uuid will not do.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    # Inserted directly rather than through `register_user/2`: registration
    # runs the rate limiter, whose ETS backend is not started in this
    # suite, and none of these tests are about registration.
    %PhoenixKit.Users.Auth.User{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          email: "commenter-#{n}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("ValidPassword123!"),
          confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          is_active: true
        },
        attrs
      )
    )
    |> TestRepo.insert!()
  end

  @doc "A published comment on a throwaway resource."
  def comment_fixture(user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, comment} =
      PhoenixKitComments.create_comment(
        Map.get(attrs, :resource_type, "test_resource"),
        Map.get(attrs, :resource_uuid, Ecto.UUID.generate()),
        user.uuid,
        Map.merge(%{content: "comment #{n}"}, Map.drop(attrs, [:resource_type, :resource_uuid]))
      )

    comment
  end
end
