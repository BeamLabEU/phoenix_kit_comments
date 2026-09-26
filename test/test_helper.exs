# Test helper for PhoenixKitComments.
#
# Two levels:
#
#   * unit — schemas, changesets, pure functions, the markdown sanitiser.
#     Always run, no database needed.
#   * integration — tagged `:integration` via `PhoenixKitComments.DataCase`,
#     excluded automatically when PostgreSQL is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_comments_test
#
# The comments tables live in CORE's versioned chain, not in this module —
# so the schema is built by `PhoenixKit.Migration.ensure_current/2`, the
# same call a host app makes. There is no module-owned DDL to run after it.

support_dir = Path.expand("support", __DIR__)

for file <- [
      "test_repo.ex",
      "data_case.ex",
      "activity_log_assertions.ex",
      "test_layouts.ex",
      "hooks.ex",
      "test_router.ex",
      "test_endpoint.ex",
      "live_case.ex"
    ] do
  Code.require_file(Path.join(support_dir, file))
end

alias PhoenixKitComments.Test.Repo, as: TestRepo

db_name = Application.get_env(:phoenix_kit_comments, TestRepo)[:database]

repo_available =
  try do
    {:ok, _} = TestRepo.start_link()

    # The module broadcasts on create/edit/delete/react. Without a PubSub server
    # `broadcast_change/3` lands in its own rescue, so a test asserting a
    # subscriber receives anything would fail for the wrong reason.
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKit.PubSub)

    # Core's own writes (trashing a file, folder events) announce on its
    # internal manager; without it they raise "unknown registry" from
    # inside a storage call this suite makes.
    case PhoenixKit.PubSub.Manager.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # `start_link/0` connects lazily, so it succeeds against a database that
    # does not exist — the first real query is what fails, and by then every
    # test is already running and timing out one settings read at a time.
    # Ask a question first.
    TestRepo.query!("SELECT 1")
    PhoenixKit.Migration.ensure_current(TestRepo, log: false)

    # Probed BEFORE sandbox mode goes manual — after that a query from this
    # process has no connection ownership and fails for a reason that has
    # nothing to do with what is being asked.
    #
    # Attribution needs core V166. `mix.exs` still declares the older floor
    # (the core release carrying V166 is unpublished), so a plain `mix test`
    # builds a schema without those columns and every query on `Comment`
    # fails with "column does not exist" — which looks like a broken suite
    # rather than a version gap. Run with
    # PHOENIX_KIT_PATH=../phoenix_kit to exercise the integration half.
    %{rows: [[present]]} =
      TestRepo.query!("""
      SELECT COUNT(*) FROM information_schema.columns
      WHERE table_name = 'phoenix_kit_comments' AND column_name = 'author_display_name'
      """)

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

    if present == 0 do
      IO.puts("""

        Integration tests excluded — core in this build predates V166, so
        `phoenix_kit_comments.author_display_name` does not exist.
        Run: PHOENIX_KIT_PATH=../phoenix_kit mix test
      """)
    end

    present > 0
  rescue
    e ->
      IO.puts("""

        Integration tests excluded — could not reach "#{db_name}".
        Run: createdb #{db_name}

        (#{Exception.message(e)})
      """)

      false
  end

# The LiveView test endpoint. Skipped without a repo — those tests are
# `:integration` and excluded in that case anyway.
if repo_available do
  {:ok, _pid} = PhoenixKitComments.Test.Endpoint.start_link()
end

if repo_available do
  ExUnit.start()
else
  ExUnit.start(exclude: [:integration])
end
