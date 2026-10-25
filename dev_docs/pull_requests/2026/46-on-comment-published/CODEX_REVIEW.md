# PR #46 — Approval callback and migration recheck

Reviewer: Codex. Reviewed 2026-10-25 against main at `267885a`.
Scope: PR #46, its Claude follow-up, and adjacent commit `3f1e0b3`.
Recent PRs #39–45 have separate Codex review documents.
Verdict: approval needs the fixes below; migration comparison passed.

## BUG - MEDIUM — Retrying a stale pending struct repeats the callback

The callback guard checked the caller's `comment.status`. Calling
`approve_comment(comment)` twice with the same pending struct sent two
notifications, even sequentially. Concurrent moderators have the same problem.
The existing repeat-approval test reloaded the struct before the second call,
which concealed the defect. This is more than the concurrency-only nitpick
recorded by Claude: an ordinary retry violates the callback's documented
transition semantics. The projects consumer turns this callback into notices.

Fixed by locking and rereading the stored comment inside a transaction and
basing dispatch on its actual previous status. A retry reads `published` and
does not dispatch. Notifications, broadcasting and audit logging run after
this transaction returns, so host callback work does not hold the row lock.

## BUG - HIGH — Stale approval can republish a deleted comment

The deleted-row guard also inspected only the caller's struct. Loading a
pending comment, deleting it, and approving the original struct published
the deleted row and invoked the new callback. This bypasses the documented
separation between approval and restoration. The guard weakness predates #46;
the new callback additionally notifies readers about that unintended publish.

The same locked reread now refuses the actual deleted row with
`{:error, :comment_deleted}`. Missing rows return `{:error, :not_found}`.
Failed approval emits no callback, broadcast or approval audit row.

## BUG - MEDIUM — Stale published structs can report approval without publishing

When the caller's struct says `published` but the database row has since
returned to `pending`, Ecto sees no status change in the changeset and skips
the UPDATE. Approval reports `{:ok, published_struct}` while the stored row
remains pending, and the callback never fires. Reading the actual row before
building the changeset fixes both the stored status and callback decision.

## Adjacent migration commit `3f1e0b3`

Read `Migrations`, the test-helper adoption step, conformance tests, core's
module-update protocol, and the standalone checker. No correctness defect
found in the reviewed V1 paths. The chain preserves UUIDv7 defaults, FK delete
actions, named constraints/indexes, prefix threading and marker-only rollback.
Existing V1 statements were not changed.

The pinned Hex core 2.64.1 does not ship `ModuleChainCheck`, so the normal
suite excludes that one test. For this review, loaded the actual checker,
ownership registry and expression differ from the local core checkout into
an isolated Mix process, leaving the dependency and lockfile untouched. Ran
`ModuleChainCheck.check(Test.Repo, Migrations)` against the published core's
real migration chain. Result: `:ok`. It builds core plus module, rebuilds only
the module tables in a scratch schema, and compares columns, defaults,
indexes, constraints and triggers. The checker cleans up its scratch schema.

## Verification

- Original baseline: 153 tests, 0 failures, 1 excluded.
- All three stale-struct regressions failed against the original code.
- A real concurrent test uses committed fixtures and separate connections;
  both moderators succeed and exactly one published callback is observed.
- Approval tests cover refusal side effects and `broadcast: false` /
  `log: false`; existing moderator actor/audit tests pass.
- The #41 explicit-host-enabled regression failed before its fix.
- Final suite: 160 tests, 0 failures, 1 excluded (checker exercised separately).
- `mix precommit`: passed (compile with warnings as errors, dependency checks,
  Hex audit, formatting, strict Credo and Dialyzer). Dialyzer's two existing
  Gettext opaque-type warnings are covered by the unchanged ignore filter.

Callback delivery remains best-effort, as with the existing lifecycle hooks;
this change does not add durable delivery or a transactional outbox. Sequential
and concurrent approvals of a continuously published row do not redispatch.

See [FOLLOW_UP.md](FOLLOW_UP.md) for the resolution record.
