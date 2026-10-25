# Codex follow-up — 2026-10-25

- **BUG - MEDIUM: stale pending retries duplicate publication callbacks — fixed.**
  Approval locks and reads the stored row; dispatch uses its previous status.
  Covered by a sequential stale retry and two simultaneous approvals using
  separate PostgreSQL connections.
- **BUG - HIGH: stale approval republishes a deleted row — fixed.**
  The deleted check now runs against the locked current row. Regression proves
  deletion remains in force. Refusal emits no approval side effects.
- **BUG - MEDIUM: stale published struct reports a publish that never happened — fixed.**
  The changeset is built from the current row, so a stored pending status is
  actually updated and the handler is notified.
- Claude's documentation additions remain in place; its review file was not
  edited. The earlier concurrency nitpick is superseded by these reproduced
  defects and fixes.
- Adjacent migration commit `3f1e0b3` reviewed with no changes required;
  standalone schema comparison passed using core's local checker against the
  pinned Hex migration chain.

Validation and delivery limits are recorded in [CODEX_REVIEW.md](CODEX_REVIEW.md).
