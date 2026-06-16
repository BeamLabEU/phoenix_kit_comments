# PR #23 Review — Reaction resource-handler callbacks for comment notifications

- **Author:** Alexander Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/23
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-16 (review is post-hoc)
- **Diff size:** +70 / −2, 3 files (`lib/phoenix_kit_comments.ex`, `CHANGELOG.md`, `mix.exs`); bump 0.2.8 → 0.2.9

## Summary

Adds four optional, duck-typed resource-handler callbacks symmetric with the
existing `on_comment_created/3` / `on_comment_deleted/3` pair:
`on_comment_liked/3`, `on_comment_unliked/3`, `on_comment_disliked/3`,
`on_comment_undisliked/3`. `like_comment/2` and its three siblings now dispatch
(best-effort, after the existing PubSub broadcast) to the registered handler
with a `%{comment: %Comment{}, liker_uuid: binary}` payload. The new private
`maybe_notify_on_reaction/5` mirrors `notify_resource_handler/4`, guards on
`function_exported?/3`, and fires only when the reaction state actually changed.
Purely additive.

## Verdict

**Approve.** Correct and well-scoped. The only substantive note is an
efficiency one (#1): the change adds a second, unconditional DB read per
reaction toggle on a hot path. Worth a follow-up but not blocking.

## What's good

- **State-change gating is exactly right.** The head
  `maybe_notify_on_reaction({:ok, action}, comment_uuid, liker_uuid, callback, action)`
  reuses `action` as a non-linear pattern, so the callback fires only when the
  result's action equals the expected action passed by the caller. `{:ok,
  :already_liked}`, `{:error, :not_found}`, and rollbacks all fall through to
  the no-op clause. This matches the gating already used by
  `maybe_broadcast_reaction/2` and reads cleanly.
- **Fires after commit, never inside the transaction.** For `like`/`dislike`
  the dispatch happens after `repo().transaction/1` returns; for
  `unlike`/`undislike` after `maybe_remove_reaction/4`. A slow or throwing host
  handler can't poison the DB write.
- **Defensive dispatch.** `notify_resource_handler/4` is `rescue`-wrapped and
  `Logger.warning`s, and the `get_comment/1 == nil` branch is handled (comment
  deleted between the toggle and the lookup → `:ok`). Best-effort semantics are
  honest.
- **Payload shape is the correct call.** Passing `%{comment, liker_uuid}` rather
  than the bare comment is necessary — the comment row carries the *author*, not
  the *reactor* — and keeping it a map preserves the 3-arity contract and stays
  extensible. The asymmetry vs. create/deleted is documented in both the
  moduledoc and CHANGELOG.
- **Docs match behavior.** Moduledoc, commit message, and CHANGELOG all
  correctly state the "only on actual state change," "optional," and
  "self-action skipping is the host's job" semantics.
- **Compiles clean** (`mix compile` green).

## Findings

1. **(Medium — efficiency) Unconditional extra full-row `SELECT` per reaction.**
   `maybe_notify_on_reaction/5` calls `get_comment/1` (a `SELECT *`)
   *unconditionally* on every successful toggle, regardless of whether any
   handler is registered for the resource. Combined with
   `maybe_broadcast_reaction/2`, which independently runs `comment_resource/1`
   (a lightweight `SELECT {resource_type, resource_uuid}`) for the same row,
   every like/dislike now issues **two reads of the same comment** where the
   pre-PR path issued one. Because these callbacks are brand-new, *no existing
   host registers them* — so today this is pure overhead on the most
   frequently-called write path in the library.

   Suggested follow-up: fetch once and serve both. `maybe_notify_on_reaction`
   already loads the full comment, which is a superset of what
   `maybe_broadcast_reaction` needs (`resource_type` / `resource_uuid`).
   Collapsing the two helpers into a single `after_reaction/4` that does one
   lookup, broadcasts, then notifies would bring the query count back to one.
   (`get_comment/1` doesn't `rescue` where `comment_resource/1` does, so preserve
   that guard when merging.) Cheaper still would be to gate the lookup on handler
   presence, but that needs `resource_type` first, so the single-fetch unification
   is the clean win.

2. **(Low) No test coverage for the new dispatch.** Consistent with the existing
   suite — `phoenix_kit_comments_test.exs` exercises behaviour/config callbacks
   and changesets but has no DB-backed reaction tests — so this isn't a
   regression. Still, the state-change gating in #1's head and the
   `:already_liked`/`{:error, :not_found}` no-op cases are exactly the kind of
   branch logic a small test (with a stub handler module + sandbox repo) would
   pin down cheaply. Worth adding alongside the #1 refactor.

3. **(Nit) Callbacks remain undeclared.** Like create/deleted before them, the
   reaction callbacks are duck-typed via `function_exported?/3` with no
   `@callback` / `@optional_callbacks` behaviour anywhere. This PR is correctly
   consistent with the established pattern, so no change is requested — but the
   handler contract (now six optional callbacks) is large enough that a documented
   behaviour with `@optional_callbacks` would give hosts compile-time names and a
   single place to read the contract. A future-cleanup item, not for this PR.

## Conclusion

Additive, correct, and faithful to the existing resource-handler conventions.
The lone actionable item is the redundant per-reaction read in finding #1;
folding the broadcast and notify lookups into a single fetch would restore the
original one-query cost while keeping the new callbacks. Approve as merged.
