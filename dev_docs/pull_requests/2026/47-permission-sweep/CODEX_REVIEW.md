# PR #47 — Scoped moderation and permission split

Reviewer: Codex. Reviewed 2026-10-27 against `bcef4af`.
PR: https://github.com/BeamLabEU/phoenix_kit_comments/pull/47
Author: Max Don (`mdon`). Verdict: fixes applied for the findings below.
Recent merged PRs #38–46 already have Codex review records.

## BUG - MEDIUM — An open dashboard keeps data from the previous scope

Core swaps `phoenix_kit_current_scope` when permissions or the active role
change, then halts its `handle_info` hook. The PR updates email visibility
from that live scope, but the comment list, counts, type filters, settings
shortcut and open modal still come from the previous list load. Revoking
`comments.moderate_all` therefore leaves unmanaged comment bodies and resource
information on screen; granting it does not load newly accessible records.

Added `Index.phoenix_kit_scope_changed/1`, using core's existing callback to
refresh every dashboard read from one fresh moderation rule and close the
modal. Losing the base permission clears the dashboard before core performs
its normal eviction. The callback does not navigate: core decides navigation
after calling it, and attempting both would prepare two redirects.
The callback and its dispatcher exist in the declared core floor, 2.38.0.

Regression tests cover a downgrade with an open out-of-scope modal, loss of
the base key, and promotion to site-wide moderation. They check bodies,
parent snippets, counts, type filters, the settings shortcut and the modal.
The test scope-refresh hook now calls core's real callback dispatcher.

## BUG - MEDIUM — Hosts without a scope keep stale moderation controls after updates

`render_scope/1` reuses its internally built scope whenever the viewer's UUID
matches. An explicit component update after a revoke still renders Edit and
Delete for someone else's comments. A later grant likewise never reaches the
controls until remount. This is narrower than the already-fixed stale WRITE
scope: event authorization correctly rebuilds its scope, but rendering does
not do what the follow-up's "until the next update" wording promises.

The fallback render scope is now built once per component update. A host
supplying `pk_scope` still owns its scope and must pass current values, as
documented. No permission query is added to the per-comment render loop.
The existing real-role regression still tests refused writes BEFORE any
update, then additionally checks that a partial `send_update` removes controls
after revocation and restores them after a new grant.

## Validation

- Baseline: 194 tests, 0 failures, 5 excluded.
- The four regression cases fail against the original production files and
  pass against the fixes.
- Final full suite: 197 tests, 0 failures, 5 excluded.
- `mix precommit`: passed, including compilation with warnings as errors,
  dependency checks, Hex audit, formatting, strict Credo and Dialyzer.
- The five exclusions require unpublished core migration-check/manifest APIs;
  database-backed moderation and LiveView tests run against PostgreSQL.
- Applied the project formatter to an existing assertion in the adjacent
  manifest test, as required by the formatting gate.

No changes to permission backfill policy, schema versions, package version or
release metadata. An embedded thread still needs a component update to refresh
its controls; writes continue to recheck permission on every event.
