# PR #44 — Shared storage, actor and activity tools

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: no new correctness findings after the existing restore fix.

Read the merge diff, current attachment/activity wrappers, and the producing
APIs in published core 2.64.1. Also checked the storage and actor API exports
in core's `v2.38.0` source against the declared dependency floor.

- `ResourceFolders.parent_uuid/4` validates hook answers and guards failures.
- `attach/2` preserves an existing home and creates a folder link when needed.
- `place_stored/2` restores trashed duplicates and places them transactionally;
  a failed folder attempt falls back to guarded root restoration here.
- The September follow-up guards the bare root restore against raises and
  exits. Its regression and the live/deleted/trashed folder tests still pass.
- Activity forwarding retains the action/module and actor options; the
  pipe-step returns the original mutation result even if logging fails.

Shared validation is recorded in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).
