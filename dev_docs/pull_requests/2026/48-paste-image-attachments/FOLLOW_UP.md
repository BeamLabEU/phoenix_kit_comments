# PR #48 — Codex review follow-up

The merged PR already includes the fixes from its Claude review. This file
records the additional findings in `CODEX_REVIEW.md`.

- **Schema prefix:** replaced the unqualified media-table SQL with an Ecto
  subquery inside the existing `NOT EXISTS` predicate. SQL generation and
  scratch-schema integration tests protect the behavior.
- **Recorder lifecycle:** pending permission requests cannot outlive their
  composer with an active microphone; duplicate starts are ignored and
  destroyed recorders cannot upload late events. Missing recorder support and
  startup errors use the existing localized error codes.
- **Hook regression coverage:** committed `test/js/comments_hooks_test.cjs`
  and documented its Node test command.

The wider core orphan-finder prefix limitations are documented in the review
and remain outside this module's changes.

## Verification

- Full suite against the locked Hex PhoenixKit 3.0.0 and an isolated local
  PostgreSQL 18 database: **255 tests, 0 failures, 0 excluded**.
- Focused reference/removal suite: **23 tests, 0 failures**. Recompiling the
  original production modules in a separate VM gives **5 failures**, covering
  both prefix cases and the three privacy/revocation cases.
- `node --test test/js/comments_hooks_test.cjs`: **14 tests, 0 failures**.
  The five selected lifecycle/drop regressions fail against the original bundle.
- `node --check priv/static/assets/phoenix_kit_comments.js`: passed.
- `mix precommit`: passed (warnings-as-errors compilation, dependency checks,
  Hex audit, format check, strict Credo and Dialyzer).

The shared test server was in recovery mode. Tests used a disposable server
under `/tmp`, with `PGHOST=127.0.0.1`, `PGUSER=postgres`,
`PGDATABASE=phoenix_kit_comments_review_test`, `PGPOOL=8` and `--max-cases 6`;
no repository database configuration was changed.
