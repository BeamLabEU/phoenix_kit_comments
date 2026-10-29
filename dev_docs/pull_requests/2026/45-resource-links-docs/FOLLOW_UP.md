# PR #45 follow-up — resource_links/0 documentation

Triaged 2026-10-29 in the quality sweep of PR #48. Reviewers: Claude
(2026-10-15), Codex (rechecked 2026-10-25).

## Fixed (pre-existing)

All four findings were fixed by the review itself; re-verified in the current
README and source.

- ~~**IMPROVEMENT - MEDIUM:** the README callback list omitted the reaction
  callbacks.~~ `on_comment_liked/3`, `on_comment_unliked/3`,
  `on_comment_disliked/3`, `on_comment_undisliked/3` are listed with the no-op
  rule (`README.md`, "Resource handler callbacks").
- ~~**IMPROVEMENT - MEDIUM:** module templates and Settings templates differ in
  prefix handling, undocumented.~~ The README paragraph after the
  `resource_links/0` example says a module template is prefixed once at render,
  so a pre-prefixed path is doubled.
- ~~**NITPICK:** the README example defined `resource_links` twice.~~ The
  second form is introduced with `# or, a link only …`.
- ~~**NITPICK:** a ragged rewrapped line in `resource_handler.ex`.~~ Rewrapped.

## Files touched

None. This pass was verification only.

## Verification

`mix test`: 217 tests, 0 failures. `mix precommit`: passes.

## Open

None.
