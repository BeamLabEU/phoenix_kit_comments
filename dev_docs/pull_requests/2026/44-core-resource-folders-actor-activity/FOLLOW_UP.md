# PR #44 follow-up — core resource folders, actor and activity

Triaged 2026-10-29 in the quality sweep of PR #48. Reviewers: Claude
(2026-09-26), Codex (rechecked 2026-10-25).

## Fixed (pre-existing)

- ~~**BUG - MEDIUM:** the root restore of a trashed duplicate called
  `Storage.restore_file_into/2` outside core's guard and could crash an
  upload.~~ Fixed at review time (released in 0.4.9, `3992293`):
  `Attachments.place_file(%Storage.File{status: "trashed"}, nil)` rescues and
  catches exit/throw, logs only `ResourceFolders.describe_failure/1`'s shape and
  answers `:ok` (`lib/phoenix_kit_comments/attachments.ex`). Its regression test
  is in `test/phoenix_kit_comments/attachments_test.exs` and passes.

## Not applicable

- **NITPICK:** restoring a re-uploaded trashed file at the media root when no
  hook is configured is a behaviour change. The review recorded it as intended
  and the better outcome, not as something to change; it is tested ("with no
  folder, a trashed file still comes back live").

## Files touched

None. This pass was verification only.

## Verification

`mix test`: 217 tests, 0 failures. `mix precommit`: passes.

## Open

None.
