defmodule PhoenixKitComments.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_comments` — the protocol
  core's `mix phoenix_kit.update` discovers through `migration_module/0`:
  `current_version/0`, `migrated_version_runtime/1`, an idempotent `up/1` and a
  version-aware `down/1`. Same shape as `phoenix_kit_locations`' chain.

  ## What V1 is

  An ADOPTION step for the four tables core's chain creates for this module:
  `phoenix_kit_comments`, `phoenix_kit_comments_likes`,
  `phoenix_kit_comments_dislikes` and `phoenix_kit_comment_media`. Their shape
  is core's V135 baseline plus V164 (the `fk_comments_user_uuid` delete action)
  and V166 (the four attribution columns, their partial index and CHECK); the
  statements below re-state what a fresh core install builds today, with core's
  exact object names.

    * On every existing install the tables are already there: each `CREATE
      TABLE IF NOT EXISTS`, guarded `DO $$ … pg_constraint … $$` block and
      `CREATE INDEX IF NOT EXISTS` finds its target and does nothing. The only
      new object is the `pkcmt_schema:1` marker.
    * On an install whose core no longer creates the tables, the same
      statements create them, identical to what core built.
      `test/integration/migrations_build_alone_test.exs` proves that against
      core's chain (core's `PhoenixKit.TestSupport.ModuleChainCheck`).

  From V1 on, this chain owns the tables' shape: a change to them is a new
  version here, never a core migration (core enforces that since V223; see
  core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's
  `ExpectedSchema` manifest hands these tables over, a version that reshapes an
  object the manifest declares must first take it out of the manifest, or
  `mix phoenix_kit.repair` restores the old shape; a version that only adds
  objects the manifest never names needs no core step.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it never drops a table. The rows are
  people's comments, and on every current install core created the tables.
  `test/phoenix_kit_comments/migrations_test.exs` pins this by asserting that no
  statement this module can emit matches `DROP`, `TRUNCATE` or `DELETE`.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.

  The migrated version is a `pkcmt_schema:<N>` `COMMENT ON TABLE` marker on
  `phoenix_kit_comments`; a table without one reads as version 0 — the shape
  core built before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkcmt_schema:"
  @version_table "phoenix_kit_comments"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkcmt_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkcmt_schema:<N>` marker when present; a marker-less table
  reads as `0` (core's shape — V1 is purely adoptive, there is no pre-chain
  content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already created
  the tables and on one with none of them.

  V1 order: every `CREATE TABLE`, then every constraint guard (primary keys,
  then foreign keys, then the CHECK), then every index, then the version marker
  last.

  `target` selects how much of the chain to emit (default `current_version/0`);
  the wrapper migration core's update task generates passes an explicit
  `:version`, and a stale wrapper asking for an older version must not receive
  a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(prefix, p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of the four tables core's chain creates ─────────────────

  defp v1_statements(prefix, p) do
    [tables(p), constraints(prefix, p), indexes(p)]
  end

  # Columns, types, defaults and order as a fresh core install builds them:
  # V135's columns, then V166's four attribution columns.
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_comments (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "resource_type" character varying(50) NOT NULL,
        "resource_uuid" uuid NOT NULL,
        "parent_uuid" uuid,
        "content" text NOT NULL,
        "status" character varying(20) DEFAULT 'published'::character varying NOT NULL,
        "depth" integer DEFAULT 0 NOT NULL,
        "like_count" integer DEFAULT 0 NOT NULL,
        "dislike_count" integer DEFAULT 0 NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "user_uuid" uuid,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "author_display_name" text,
        "attribution_mode" text,
        "attributed_project_uuid" uuid,
        "attributed_label" text
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_comments_likes (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "comment_uuid" uuid NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "user_uuid" uuid NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_comments_dislikes (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "comment_uuid" uuid NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "user_uuid" uuid NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_comment_media (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "comment_uuid" uuid NOT NULL,
        "file_uuid" uuid NOT NULL,
        "position" integer NOT NULL,
        "caption" text,
        "inserted_at" timestamp(0) without time zone NOT NULL,
        "updated_at" timestamp(0) without time zone NOT NULL
      )
      """
    ]
  end

  # Core's constraint names. `fk_comments_*` are core's V135 names; the
  # comment-media FKs are Ecto's default names from the same baseline.
  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_comments",
        "phoenix_kit_comments_pkey",
        "ALTER TABLE #{p}phoenix_kit_comments ADD CONSTRAINT phoenix_kit_comments_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_likes",
        "phoenix_kit_comments_likes_pkey",
        "ALTER TABLE #{p}phoenix_kit_comments_likes ADD CONSTRAINT phoenix_kit_comments_likes_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_dislikes",
        "phoenix_kit_comments_dislikes_pkey",
        "ALTER TABLE #{p}phoenix_kit_comments_dislikes ADD CONSTRAINT phoenix_kit_comments_dislikes_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comment_media",
        "phoenix_kit_comment_media_pkey",
        "ALTER TABLE #{p}phoenix_kit_comment_media ADD CONSTRAINT phoenix_kit_comment_media_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments",
        "fk_comments_parent",
        "ALTER TABLE #{p}phoenix_kit_comments ADD CONSTRAINT fk_comments_parent FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_comments(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments",
        "fk_comments_user_uuid",
        "ALTER TABLE #{p}phoenix_kit_comments ADD CONSTRAINT fk_comments_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_likes",
        "fk_comments_likes_comment",
        "ALTER TABLE #{p}phoenix_kit_comments_likes ADD CONSTRAINT fk_comments_likes_comment FOREIGN KEY (comment_uuid) REFERENCES #{p}phoenix_kit_comments(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_likes",
        "fk_comments_likes_user_uuid",
        "ALTER TABLE #{p}phoenix_kit_comments_likes ADD CONSTRAINT fk_comments_likes_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_dislikes",
        "fk_comments_dislikes_comment",
        "ALTER TABLE #{p}phoenix_kit_comments_dislikes ADD CONSTRAINT fk_comments_dislikes_comment FOREIGN KEY (comment_uuid) REFERENCES #{p}phoenix_kit_comments(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments_dislikes",
        "fk_comments_dislikes_user_uuid",
        "ALTER TABLE #{p}phoenix_kit_comments_dislikes ADD CONSTRAINT fk_comments_dislikes_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comment_media",
        "phoenix_kit_comment_media_comment_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_comment_media ADD CONSTRAINT phoenix_kit_comment_media_comment_uuid_fkey FOREIGN KEY (comment_uuid) REFERENCES #{p}phoenix_kit_comments(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comment_media",
        "phoenix_kit_comment_media_file_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_comment_media ADD CONSTRAINT phoenix_kit_comment_media_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE RESTRICT"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_comments",
        "phoenix_kit_comments_attribution_mode_check",
        "ALTER TABLE #{p}phoenix_kit_comments ADD CONSTRAINT phoenix_kit_comments_attribution_mode_check CHECK (((attribution_mode IS NULL) OR (attribution_mode = ANY (ARRAY['personal'::text, 'project'::text]))))"
      )
    ]
  end

  # Index names are core's. They stay bare on CREATE (an index lives in its
  # table's schema).
  defp indexes(p) do
    [
      "CREATE INDEX IF NOT EXISTS idx_comments_inserted_at ON #{p}phoenix_kit_comments USING btree (inserted_at)",
      "CREATE INDEX IF NOT EXISTS idx_comments_parent_id ON #{p}phoenix_kit_comments USING btree (parent_uuid)",
      "CREATE INDEX IF NOT EXISTS idx_comments_resource ON #{p}phoenix_kit_comments USING btree (resource_type, resource_uuid)",
      "CREATE INDEX IF NOT EXISTS idx_comments_resource_status ON #{p}phoenix_kit_comments USING btree (resource_type, resource_uuid, status)",
      "CREATE INDEX IF NOT EXISTS idx_comments_status ON #{p}phoenix_kit_comments USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_comments_attributed_project_idx ON #{p}phoenix_kit_comments USING btree (attributed_project_uuid) WHERE (attributed_project_uuid IS NOT NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_comments_user_uuid_idx ON #{p}phoenix_kit_comments USING btree (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_comments_likes_user_uuid_idx ON #{p}phoenix_kit_comments_likes USING btree (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_comments_dislikes_user_uuid_idx ON #{p}phoenix_kit_comments_dislikes USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_comment_media_comment_position_index ON #{p}phoenix_kit_comment_media USING btree (comment_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_comment_media_file_uuid_index ON #{p}phoenix_kit_comment_media USING btree (file_uuid)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
