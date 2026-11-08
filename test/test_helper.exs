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
# The schema is built by `PhoenixKit.Migration.ensure_current/2`, the same
# call a host app makes, then this module's own chain
# (`PhoenixKitComments.Migrations`) on top, as `mix phoenix_kit.update` runs
# it: V1 adopts the comments tables where an older core created them and
# creates them where core 3.x no longer does.

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

    # `up/1` needs an `Ecto.Migration` run; the SQL is data, so replay it.
    if PhoenixKitComments.Migrations.migrated_version_runtime() <
         PhoenixKitComments.Migrations.current_version() do
      Enum.each(PhoenixKitComments.Migrations.up_statements("public"), &TestRepo.query!/1)
    end

    # Probed BEFORE sandbox mode goes manual — after that a query from this
    # process has no connection ownership and fails for a reason that has
    # nothing to do with what is being asked.
    #
    # The attribution columns (core V166, and this module's V1) are on
    # every schema the current floor builds; the probe stays so a database
    # left behind by an older build says so, instead of failing every query
    # on `Comment` with "column does not exist".
    %{rows: [[present]]} =
      TestRepo.query!("""
      SELECT COUNT(*) FROM information_schema.columns
      WHERE table_name = 'phoenix_kit_comments' AND column_name = 'author_display_name'
      """)

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

    if present == 0 do
      IO.puts("""

        Integration tests excluded — `phoenix_kit_comments.author_display_name`
        does not exist in "#{db_name}" (a database left by an older build).
        Recreate it: dropdb #{db_name} && createdb #{db_name}
      """)
    end

    present > 0
  rescue
    e ->
      IO.puts("""

        Integration tests excluded — "#{db_name}" is not usable:
        #{Exception.message(e)}

        No database yet: createdb #{db_name}
        One left by an older build (e.g. "below this release's floor"):
          dropdb #{db_name} && createdb #{db_name}
      """)

      false
  end

# The LiveView test endpoint. Skipped without a repo — those tests are
# `:integration` and excluded in that case anyway.
if repo_available do
  {:ok, _pid} = PhoenixKitComments.Test.Endpoint.start_link()
end

# A host lists this module in core's registry; the test environment registers
# none. Without it `Scope.can?/2` cannot tell that `comments.moderate_all` is a
# sub-key of `comments` (nor that the module is on), so every sub-key check
# here would answer false for a reason no host ever sees.
:persistent_term.put(
  {PhoenixKit, :registered_modules},
  Enum.uniq([PhoenixKitComments | :persistent_term.get({PhoenixKit, :registered_modules}, [])])
)

# `migrations_build_alone_test.exs` uses core's
# `PhoenixKit.TestSupport.ModuleChainCheck`, which the first core release after
# 2.64.1 ships; against an older core in `deps/` it is excluded.
exclude =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck),
    do: [],
    else: [:requires_module_chain_check]

if repo_available do
  ExUnit.start(exclude: exclude)
else
  ExUnit.start(exclude: [:integration | exclude])
end

# The manifest test builds the module's tables with `ModuleChainCheck.build_alone/4`
# and hands the manifest to repair (`PhoenixKit.Module.expected_schema/0`); both
# arrive in the first core release after 2.64.1.
unless Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck) and
         function_exported?(PhoenixKit.TestSupport.ModuleChainCheck, :build_alone, 4) do
  ExUnit.configure(exclude: [:requires_core_expected_schema | ExUnit.configuration()[:exclude]])
end
