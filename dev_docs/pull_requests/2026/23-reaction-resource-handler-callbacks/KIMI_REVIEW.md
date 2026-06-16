# PR #23 Review — Reaction resource-handler callbacks for comment notifications

- **Author:** Alexander Don (`alexdont`)
- **Reviewer:** Kimi
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/23
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-16; post-hoc review with follow-up fix already applied
- **Diff size:** +70 / −2, 3 files (`lib/phoenix_kit_comments.ex`, `CHANGELOG.md`, `mix.exs`); bump 0.2.8 → 0.2.9

## Summary

PR #23 adds four optional, duck-typed resource-handler callbacks for comment
reactions, symmetric with the existing `on_comment_created/3` /
`on_comment_deleted/3` pair:
`on_comment_liked/3`, `on_comment_unliked/3`, `on_comment_disliked/3`,
`on_comment_undisliked/3`. The reaction functions (`like_comment/2`,
`unlike_comment/2`, `dislike_comment/2`, `undislike_comment/2`) dispatch
(best-effort, after the existing PubSub broadcast) to the registered handler
with a `%{comment: %Comment{}, liker_uuid: binary}` payload. The callback fires
only when the reaction state actually changed; `:already_liked`,
`:already_disliked`, and `{:error, :not_found}` no-ops are ignored. Purely
additive.

## Verdict

**Approve.** The implementation is correct, tightly scoped, and consistent with
the established resource-handler pattern. The one material efficiency concern
raised by the prior review has been fixed by unifying the broadcast and notify
lookups into a single comment read. I am leaving two lower-severity follow-ups
noted below: missing tests for the new dispatch paths, and a housekeeping note
that the review file was initially committed outside the agreed location.

## What's good

- **Clean additive design.** The new callbacks are optional and guarded by
  `function_exported?/3`; existing handlers keep working unchanged.
- **Correct state-change gating.** `after_reaction/3` only matches
  `{:ok, action}` when `action in [:liked, :unliked, :disliked, :undisliked]`,
  so no-ops and errors fall through to the zero-cost clause.
- **Post-commit side effects.** Broadcast and handler dispatch happen only after
  the DB transaction or delete has succeeded, so a slow or crashing host handler
  cannot roll back an already-committed reaction.
- **Honest best-effort semantics.** The unified `after_reaction/3` is wrapped in
  a single `rescue` and logs on failure, preventing a transient post-commit read
  error from surfacing a successful reaction as a failure to the caller.
- **Good payload shape.** Passing `%{comment: comment, liker_uuid: liker_uuid}`
  preserves the 3-arity handler contract and correctly surfaces the reacting
  user, which the `Comment` row itself does not contain.
- **Documentation is consistent.** Moduledoc and CHANGELOG accurately describe
  the optional nature, state-change gating, and self-action skipping policy.

## Findings

1. **(Process — medium) Review file was committed at repository root.**
   ✅ **Fixed** as part of this review.
   `CLAUDE_REVIEW.md` was added at the repository root rather than under
   `dev_docs/pull_requests/2026/23-reaction-resource-handler-callbacks/` as
   required by `AGENTS.md`. This makes PR review history harder to discover and
   breaks the convention used by every other review in the repo.

   Resolution: moved the existing `CLAUDE_REVIEW.md` into the correct directory
   and added this `KIMI_REVIEW.md` alongside it.

2. **(Testing — medium) No automated coverage for reaction callbacks.**
   The new dispatch paths — real state change vs. `:already_liked` / `:already_disliked`
   no-ops, `{:error, :not_found}`, correct `liker_uuid` payload, and the
   `function_exported?/3` guard — are not exercised by the existing unit tests.
   The current suite is intentionally DB-free, so adding full integration tests
   would require wiring `PhoenixKit.DataCase` and a test Repo. A lighter first
   step would be to extract the callback-name mapping and dispatch gating behind
   a testable boundary, or to add a minimal handler stub test once a DB-backed
   test harness is available. This is the same gap noted in the prior review and
   remains open.

3. **(Documentation — low) CHANGELOG does not mention the follow-up optimization.**
   The post-PR commit `72f1fac` folded the two per-reaction lookups into one and
   removed the now-unused `comment_resource/1` helper. Because `0.2.9` has not
   been tagged yet, the changelog can still reflect this improvement. It is a
   user-visible performance win (one query per reaction instead of two) and
   tightens error handling, so it deserves a line under the 0.2.9 section.

4. **(Design observation — low) Reaction callbacks remain duck-typed.**
   Like the create/delete callbacks before them, the reaction callbacks are
   discovered via `function_exported?/3` with no formal `@callback` or
   `@optional_callbacks` behaviour. This is consistent with the existing pattern
   and not a request for this PR, but the handler contract is now six optional
   callbacks. A single documented behaviour would give hosts compile-time names,
   a single source of truth for arity/shape, and better IDE support. Worth
   considering as future cleanup.

## Post-review actions applied

- Moved `CLAUDE_REVIEW.md` from repository root to
  `dev_docs/pull_requests/2026/23-reaction-resource-handler-callbacks/`.
- Added this `KIMI_REVIEW.md` to the same directory.
- Added a CHANGELOG entry under 0.2.9 documenting the follow-up lookup
  unification and improved error handling.

## Conclusion

PR #23 is a well-scoped, additive feature that fills a real gap in the
resource-handler contract. The implementation follows existing conventions and
the one meaningful runtime concern (extra per-reaction DB read) has already been
resolved on `main`. The remaining items are test coverage, process housekeeping,
and optional future typing of the handler behaviour. Approve as merged.
