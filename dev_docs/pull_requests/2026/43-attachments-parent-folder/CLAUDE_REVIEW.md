# PR #43 — Comment attachments can be placed by the host into the record's folder

**Author:** Timujeen (timujinne)
**Reviewer:** Claude (post-merge review, 2026-09-15)
**Verdict:** Approve with fixes. The feature is sound and mirrors
`phoenix_kit_projects`' hook. But its "a failing hook keeps today's
behaviour" promise only covered one of three failure paths, and the other
two crash the comment component mid-upload. Both fixed in this pass, with
tests that reproduced them first.

---

## What the PR does, checked against the code

- `PhoenixKitComments.Attachments.parent_folder_uuid/3` reads
  `config :phoenix_kit_comments, :attachments_parent_folder, {mod, fun}` and
  calls `fun(:comment_attachment, actor_uuid, %{resource_type, resource_uuid})`
  (or the 2-arity form). Same contract shape as
  `PhoenixKitProjects.Attachments.parent_folder_uuid/2`.
- `CommentsComponent.store_entry` places each stored file through core's
  `Storage.attach_file_to_folder/2`. **Checked in `deps/phoenix_kit`:** that
  function adopts a homeless file, is a no-op for a file already homed there,
  and adds an idempotent `FolderLink` for a file homed elsewhere — it never
  moves a file out from under another folder. It predates core 2.0
  (1.7.x changelog), so the `~> 2.0` floor is safe.
- The tighter `{:ok, %Storage.File{} = file}` match in `store_entry` is safe:
  `Storage.store_file/2` returns a `%Storage.File{}` on both the dedupe
  branch (`get_file_by_user_checksum`) and the new-file insert.

## Findings

### 1. BUG - HIGH — a stale folder uuid crashes the upload (fixed)

Only `parent_folder_uuid/3` was wrapped in `rescue`; the placement was not.
When the hook answers the uuid of a folder deleted since the host cached it,
core adopts the (homeless, freshly-uploaded) file with a plain
`Ecto.Changeset.change/2` that declares no FK constraint, so
`phoenix_kit_files_folder_uuid_fkey` **raises** `Ecto.ConstraintError`
instead of returning `{:error, changeset}`. That raise happens inside
`consume_uploaded_entries/3`: the LiveComponent crashes after the files are
already stored, and the user's comment is lost. Reproduced by
`"a folder uuid that no longer exists does not raise"` before the fix.

**Fix:** new `Attachments.place_file/2` is total — `rescue` plus
`catch :exit`, logs and returns `:ok`, leaving the file at the root.

### 2. BUG - MEDIUM — a hook that exits is not caught (fixed)

`rescue` does not cover exits. A host hook doing a `GenServer.call` to a dead
or slow process (a very plausible "find or create the order's folder"
implementation) exits straight through into the component — same crash as
above. AGENTS.md already requires `rescue` + `catch :exit` around host code.
Reproduced by `"a hook that exits is swallowed…"`.

**Fix:** `catch :exit` in `parent_folder_uuid/3`, logging the payload-free
shape via the existing `exit_summary/1` (exposed as `@doc false
PhoenixKitComments.describe_exit/1`) — an exit reason from
`GenServer.call` carries the call arguments.

### 3. BUG - MEDIUM — a non-uuid answer reached the uuid column (fixed)

`{:ok, uuid} when is_binary(uuid)` accepted any string; `"order-42"` would
then raise a cast error at placement (the same crash path as #1). Answers are
now run through `Ecto.UUID.cast/1` and anything else means "media root".

### 4. IMPROVEMENT - MEDIUM — hook called once per file (fixed)

`store_entry` asked the hook for every entry, so a 4-attachment comment ran
host code (possibly a folder find-or-create chain) four times for one answer.
`consume_attachments/1` now asks once and hands the folder uuid to every
`store_entry`. `place_stored_file/4` is kept as a convenience wrapper.

### 5. IMPROVEMENT - MEDIUM — the contract was undocumented (fixed)

The hook lives under `:phoenix_kit_comments` app env — unlike the resource
handlers, which are `:phoenix_kit` — and was documented only in the new
module's `@moduledoc`. Added to AGENTS.md "Host contracts" and a README
section.

### 6. NITPICK — files are placed before the comment is inserted (not fixed)

Placement runs in the consume callback, before `create_comment/4`. If the
insert then fails (precheck already rejected depth/length/cap, so this is a
DB-level failure), the uploads sit in the record's folder with no comment
referencing them — where before they sat as root-level strays. Deferring
placement until after the insert means carrying structs out of
`partition_upload_results/1` and a second load; not worth it for a rare path
that already leaked files before this PR.

### 7. NITPICK — checksum dedupe can adopt an older upload (not fixed, core rule)

`store_file/2` returns the user's existing file when the checksum matches.
If that earlier file is still homeless (uploaded before the hook was
configured, or used somewhere that doesn't set a folder), it is adopted as
home by this record's folder rather than linked. That is core's documented
`attach_file_to_folder/2` rule, shared by the media selector; changing it
belongs in core.

### Outside this PR (core)

Core's `orphaned_files_query/0` has no `phoenix_kit_comment_media` check
among its optional tables, and does not treat a folder home as a reference.
Comment attachments therefore look orphaned to the storage orphan finder
whether or not they are placed in a folder. Pre-existing and core-side;
recorded here so it isn't rediscovered as a regression of this PR.

## Tests added

`test/phoenix_kit_comments/attachments_test.exs`: 2-arity hook, exiting
hook, stale folder uuid, non-uuid answer, uuid-only map loaded before
placing, `place_file/2` with `nil`. The exiting-hook, stale-folder and
non-uuid tests were run red against the merged code before the fix, and the
whole file green after.
