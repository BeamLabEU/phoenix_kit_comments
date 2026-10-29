# PR #43 follow-up — attachment parent folder hook

Triaged 2026-10-29 during the quality sweep of PR #48. Reviewers: Claude
(2026-09-15), Codex (rechecked 2026-10-25).

## Fixed (pre-existing)

- ~~**BUG - HIGH:** a stale folder uuid crashed the upload.~~ Fixed at review
  time: `Attachments.place_file/2` rescues and catches exits; later moved onto
  core's `ResourceFolders` (#44). Tested in
  `test/phoenix_kit_comments/attachments_test.exs`.
- ~~**BUG - MEDIUM:** a hook that exits was not caught.~~ Fixed at review time
  (`catch :exit` in `parent_folder_uuid/3`, payload-free log). Tested.
- ~~**BUG - MEDIUM:** a non-uuid answer reached the uuid column.~~ Fixed at
  review time (`Ecto.UUID.cast/1`, anything else means the media root). Tested.
- ~~**IMPROVEMENT - MEDIUM:** the hook ran once per file.~~ Fixed at review
  time (`consume_attachments/1` asks once per comment).
- ~~**IMPROVEMENT - MEDIUM:** the contract was undocumented.~~ Fixed at review
  time (AGENTS.md "Host contracts", README).

## Fixed (Batch 1 — 2026-10-29)

- ~~**Outside this PR (core): comment attachments look orphaned to core's
  orphan finder.**~~ On core 3.0 this is no longer only a display problem:
  core's built-in list of module tables no longer includes
  `phoenix_kit_comment_media`, so "Delete all orphaned" trashed live comment
  attachments. Fixed in this module, not in core: `file_references/0`
  (`lib/phoenix_kit_comments/file_references.ex`, wired in
  `lib/phoenix_kit_comments.ex`) declares `phoenix_kit_comment_media.file_uuid`.
  Tests: `test/phoenix_kit_comments/file_references_test.exs` (every file
  column of the schemas is declared) and
  `test/integration/file_references_test.exs` (core's own finder: an attached
  file is not an orphan, a loose one is, a soft-deleted comment still holds its
  file, every FK to `phoenix_kit_files` is declared). Shipped in PR #48.

## Skipped (with rationale)

- **NITPICK (#6): files are placed in the record's folder before the comment
  insert; a failed insert leaves them there.** Skipped. Object storage cannot
  roll back with the database transaction, so deleting the files when the
  insert fails only narrows the window (a crash between the two still leaves
  them) and adds a failure path of its own inside the upload. The orphan finder
  is the designed safety net for a file nothing references. **This holds only
  while `file_references/0` ships** (Batch 1 above): without it the orphan
  finder cannot tell these strays from live attachments, and the safety net
  deletes both. Revisit if that declaration is ever removed.

## Not applicable

- **NITPICK (#7): a checksum dedupe can adopt an older homeless upload into
  the record's folder.** Core's documented `attach_file_to_folder/2` rule,
  shared by the media selector; a change belongs in core, not here.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_comments/file_references.ex` | New: the module's file-reference pairs |
| `lib/phoenix_kit_comments.ex` | `@impl PhoenixKit.Module def file_references/0` |
| `test/phoenix_kit_comments/file_references_test.exs` | New: schema-derived coverage |
| `test/integration/file_references_test.exs` | New: core's orphan finder, FK-derived coverage |
| `AGENTS.md` | Convention line + architecture entry |
| `CHANGELOG.md` | Unreleased → Fixed entry |

## Verification

`mix test`: 226 tests, 0 failures (217 before + 9 new; the new tests were run
red without the callback: 8 of 9 fail). `mix precommit`: passes.

## Open

None.
