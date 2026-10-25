# Codex follow-up — 2026-10-25

- **BUG - MEDIUM: host `enabled: true` bypasses the module switch — fixed.**
  `effective_enabled/1` now requires the module setting when the host permits
  comments. Explicit `false` still disables them. The public attribute
  documentation describes this contract.
- The new real-LiveView regression in `comments_component_test.exs` failed
  before the fix and passes after it. The original event-time switch test
  continues to pass.
- Stale approval state, including republishing a deleted comment, is fixed
  and tested in the [#46 follow-up](../46-on-comment-published/FOLLOW_UP.md).
