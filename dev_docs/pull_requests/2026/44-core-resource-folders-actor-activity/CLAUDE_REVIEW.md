# PR #44 — Place attachments by core's folder rules; actor and activity through core

**Author:** Dmitri Don (mdon)
**Reviewer:** Claude (post-merge review, 2026-09-26)
**Verdict:** Approve with one fix. The PR swaps three hand-rolled pieces
(hook calling, file placing, actor reading, activity logging) for core
2.38's shared versions and raises the floor to match. Every swap was checked
against core 2.40.1 in `deps/`. One new path, the trashed-duplicate restore
at the media root, calls core outside core's own guard and could crash an
upload. Fixed here, with a test that failed first.

---

## What the PR does, checked against the code

- `Attachments.parent_folder_uuid/3` → `ResourceFolders.parent_uuid/4`.
  **Checked:** core's `parent_hook/4` tries arity 3 then 2, casts the answer
  to a uuid (a non-uuid is `{:error, {:bad_answer, _}}`), and guards raise,
  throw and exit; `parent_uuid/4` logs the failure's shape and answers `nil`.
  Same contract as the removed code, plus `:throw`.
- `place_file/2` → `ResourceFolders.attach/2`. **Checked:** wrapped in
  core's `safely/2`, refuses a folder that is not live
  (`:folder_unavailable`, the trashed-folder case the old code could not
  see), locks folder then file, accepts a struct or a uuid. Never raises.
- New: a trashed duplicate (storage dedupes by user+checksum and
  `store_file/2` returns the existing row as `{:ok, file}`, trashed or not)
  goes through `ResourceFolders.place_stored({:ok, file, :duplicate}, folder)`,
  which restores and attaches in one transaction; on error the file is
  restored at the root instead. **Checked:** the return shapes matched in
  the `case` (`{:ok, _}`, `{:already_attached, _}`, `{:error, _}`) are the
  full spec.
- `Activity.log/2` → `PhoenixKit.Activity.log/3`. **Checked:** core rescues
  and catches exit/throw, returning `{:error, _}`. The only caller,
  `log_comment/3`, ignores the return, so the `:ok`→`{:error, _}` change in
  failure value reaches nobody.
- `actor_opts/1` → `PhoenixKitWeb.Actor.opts/1`. **Checked:** reads a
  `%Scope{}` under `:phoenix_kit_current_scope`, falling back to
  `:phoenix_kit_current_user`. The admin `live_session` and the test hooks
  (`fake_scope/1`) both put a real `%Scope{}`, so no actor is lost.
- Floor `>= 2.38.0 and < 3.0.0`; the conformance test's admit/reject lists
  match it. `describe_exit/1` removed; no remaining callers.

## Findings

### BUG - MEDIUM: the root restore of a trashed duplicate can crash the upload — FIXED

`place_file(%Storage.File{status: "trashed"}, nil)` calls
`Storage.restore_file_into/2` directly. That is a bare `update_all` with no
guard; only the folder path is covered by core's `safely/2` inside
`place_stored/2`. A dropped connection, pool checkout exit or cast error
raises into `consume_uploaded_entries/3`. The files are already stored by
then, so the comment is lost. The module's own doc promises "nothing here
raises or exits into the caller", and the old `place_file(_, nil)` was a
no-op that could not fail. The failing folder path also falls back into this
clause, so both entry paths were exposed.

**Fix:** the clause now rescues and catches exit/throw, logging only
`ResourceFolders.describe_failure/1`'s shape and answering `:ok`.
**Test:** "a trashed file whose restore raises is logged, not raised" uses
an uncastable uuid to force the raise on both the `nil` and the folder
entry path. It failed with `Ecto.Query.CastError` before the fix.

### NITPICK: restoring at the root when there is no hook is a behaviour change — noted, not changed

With no hook configured, a re-uploaded trashed file used to stay trashed
(attached to the comment but listed nowhere in Media). Now it is restored
at the root. This is intended and tested ("with no folder, a trashed file
still comes back live"), and it is the better outcome. It is recorded here
because it affects hosts that never set the hook.
