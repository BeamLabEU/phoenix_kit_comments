# PR #46 — Add on_comment_published: a handler hears when a held comment is approved

**Author:** Max Don
**Reviewer:** Claude (post-merge review, 2026-10-25)
**Verdict:** Approve. The behaviour is correct and tested; one docs gap fixed,
one race recorded.

---

## What the PR does, checked against the code

`approve_comment/2` now calls the optional `on_comment_published/3` once when a
`pending` comment becomes `published`; `bulk_approve/2` inherits it because it
goes through `approve_comment/2`. `notify_resource_handler/4` is the same
rescue/exit-wrapped dispatcher the other callbacks use, and the new callback
is added to `@optional_callbacks`, so `ResourceHandler.event_callbacks/0` and
the dispatcher-vs-contract test in `resource_handler_test.exs` pick it up.

- Hidden → published does not fire; only a `pending` comment does, as documented.
- A deleted row is refused earlier (`{:error, :comment_deleted}`), so no event.
- `restore_comment/2` (deleted → pending/published) fires nothing; the owner
  was told at creation. Consistent.

## Findings

### IMPROVEMENT - MEDIUM — new callback missing from the user-facing docs (fixed)
The `PhoenixKitComments` moduledoc callback list and the README (both the
bullet list and the callback table) still listed only created/deleted/reaction
callbacks. A handler author reading either would not learn it exists, and the
whole point of the PR is a module that otherwise never notifies on moderated
comments. Added to all three spots. (AGENTS.md was already updated by the PR.)

### NITPICK — stale-struct check can double-fire under concurrency (not fixed)
The "once" guard is `comment.status == "pending"` on the struct the caller
passed in, not the row. Two moderators approving the same pending comment at
the same instant, each holding a stale `pending` struct, both pass the guard
and both fire. Fixing it needs a conditional `UPDATE ... WHERE status =
'pending'` (or a row lock), which is out of proportion for a notification
hook whose handlers should already be idempotent. Recorded, not changed.

### NITPICK — test coverage
`approve_callback_test.exs` covers single approve (once, not on repeat) and
bulk (pending fires, hidden does not). It does not cover a deleted row or a
handler that raises; both paths are the shared dispatcher's, tested elsewhere.

## Out of scope
Commit `3f1e0b3` (module-owned migration chain) landed directly on main
alongside this PR, not through it; not reviewed here.
