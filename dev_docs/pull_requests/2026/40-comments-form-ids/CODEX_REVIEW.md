# PR #40 — Comment form IDs

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: no new correctness findings.

Checked all three forms in the merge diff and their current rendering context.
Composer IDs include the component CID and composer suffix; edit and decoration
IDs include the CID and comment UUID. They are unique even if two component
instances display the same resource. Recursive comment rendering does not create
another LiveComponent or reuse another instance's CID.

The composer's `phx-change` enables LiveView form recovery. An ID alone does
not establish browser recovery for the other forms or Leaf's contenteditable;
this review does not claim a browser reconnect test. Current component rendering
and mutations pass through the real LiveView harness added after this PR.

Shared validation is recorded in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).
