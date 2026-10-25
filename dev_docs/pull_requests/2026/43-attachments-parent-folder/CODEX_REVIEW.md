# PR #43 — Attachment parent folder recheck

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: no remaining new correctness findings in this PR's current paths.

Traced the component's upload path through the once-per-comment parent-folder
lookup and placement helper. The hook uses the `:phoenix_kit_comments` app,
threads the resource pair and actor, and leaves storage placement semantics to
core. It does not introduce a dependency on any resource's schema.

The original hook and stale-folder defects recorded by Claude have been
superseded by the shared core implementation in #44. Current tests exercise
bad UUID answers, exiting hooks, deleted/trashed folders, existing file homes,
and trashed duplicates. Files remain consumed before the comment transaction;
the previously documented possibility of orphaned uploads after a failed
insert remains, and this review does not claim atomic storage plus comment
creation.

Shared validation is recorded in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).
