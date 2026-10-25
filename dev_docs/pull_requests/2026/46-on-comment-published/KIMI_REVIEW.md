# Kimi review — PR #46

- **PR:** Add on_comment_published: a handler hears when a held comment is approved
- **Author:** Max Don (`mdon`)
- **Merged:** 2026-10-25, merge commit `63902d2`
- **Scope:** the merged diff and its follow-up fixes through `792aa57`

## Findings

No additional bugs, improvements, or nitpicks found in the final implementation.

The original approval implementation trusted the caller's struct both for the
deleted-status guard and for deciding whether publication occurred. The current
implementation reloads and locks the stored row, checks its current status, and
uses that previous status for callback dispatch. This closes the stale-retry,
stale-deletion, and concurrent-approval cases without changing the optional
handler contract.

## Verified

- `on_comment_published/3` is declared optional and included in the dispatcher /
  behaviour conformance checks.
- Approval dispatches only for a stored `pending` to `published` transition;
  repeated approval and approval of a hidden comment do not emit it.
- `bulk_approve/2` inherits the same behavior through `approve_comment/2`.
- A stale struct cannot republish a deleted row or duplicate the callback.
- Two approvals on independent PostgreSQL connections produce one callback.
- Failed approval has no broadcast, audit, or handler side effects; successful
  approval still honors `broadcast: false` and `log: false`.
- The public moduledoc, README, behaviour docs, and AGENTS callback table agree.

## Validation

- `mix test test/integration/approve_callback_test.exs test/integration/concurrent_approval_test.exs test/resource_handler_test.exs` — 14 tests, 0 failures.
- Full `mix test` — 160 tests, 0 failures (1 excluded `:requires_module_chain_check` test).
- `mix precommit` — passed: warnings-as-errors compilation, formatting, strict Credo, and Dialyzer.
