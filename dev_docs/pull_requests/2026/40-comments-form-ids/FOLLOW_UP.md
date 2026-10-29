# PR #40 follow-up — comment form ids

Triaged 2026-10-29 in the quality sweep of PR #48.

## No findings

Claude's and Codex's reviews found no correctness defects. Re-verified against
current code: all three `<.form>`s in `CommentsComponent` carry ids —
`decoration-form-{cid}-{uuid}`, `comment-edit-form-{cid}-{uuid}` and
`comment-composer-{cid}-{suffix}` (`lib/phoenix_kit_comments/web/comments_component.ex`).
Claude's note that the repo had no LiveView harness to test them is out of
date: `Test.HostLive` now mounts the component, and
`test/integration/comments_component_test.exs` submits the composer and edit
forms through it. No test asserts the ids themselves.

## Open

None.
