# PR #47 — follow-up

- Buttons in an open thread follow the cached scope until the next update after a revoke; clicking is refused.

## Codex follow-up — 2026-10-27

- Fixed the dashboard's stale reads through core's scope-change callback:
  list, counts, filters, settings shortcut and modal now follow the new rule.
- Fixed the internally built render scope in hosts without `pk_scope`: it is
  rebuilt on every component update, matching the behavior promised above.
  Event-time authorization continues to work without waiting for an update.
- Added regressions for grant/revoke transitions and used core's actual
  callback dispatcher in the LiveView test hook.
- Validation: 197 tests, 0 failures, 5 excluded (optional migration-check and
  manifest APIs absent from the pinned core). All four regression cases fail
  against the original production files. `mix precommit` passed, including
  compilation with warnings as errors, dependency checks, Hex audit,
  formatting, strict Credo and Dialyzer. The two existing Gettext opaque-type
  warnings are covered by the unchanged Dialyzer ignore filter.
