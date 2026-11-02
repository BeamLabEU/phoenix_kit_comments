# PR #49 — Attachment removal guard and drop zone for dragged files

**Author:** alexdont (Sasha Don)
**Reviewer:** Claude (2026-11-02, against `main` at `f273a8f`, i.e. after
Codex's fixes in `d33e099`)
**Verdict:** No new findings. Codex's three fixes (conditional `@behaviour`,
labels limited to the moderation scope, drop hint restored after a patch) are
correct and tested. The rest of the PR checks out against core's contract.

---

## What the PR does, checked against the code

- **`PhoenixKitComments.RemovalGuard.places/2`.** Checked against core's
  `PhoenixKit.Modules.Storage.RemovalGuard` and its dispatcher
  (`PhoenixKitWeb.Components.MediaBrowser.Removal`, core 3.2.x):
  - Core calls the guard by `function_exported?/3`, not by the `@behaviour`
    attribute. So a host whose comments dep compiled before core gained the
    behaviour (the `Code.ensure_loaded?` branch was false then) is still
    asked. The conditional attribute only affects compile-time warnings.
  - One place per file, `file_uuid` from the database (lowercase). Core
    compares case-insensitively and rejects a place for a file it did not ask
    about; the `in ^file_uuids` filter means that cannot happen.
  - Soft-deleted and hidden comments still block. They hold the media row and
    the `ON DELETE RESTRICT` FK, so removing the file would fail late anyway.
    Their resource type is shown only through `moderation_scope/1`, which is
    computed once per call.
  - A non-uuid in `file_uuids` raises `Ecto.Query.CastError`, which core
    treats as "could not check" and fails closed. Core only sends uuids from
    its own rows, so nothing needed handling here.
  - No `release/2`, as documented. Without the callback, core shows no
    release button.
- **Drop zone** (`PhoenixKitCommentsPasteFiles`). The capture-phase
  `dragenter/over/leave/drop` handlers act only on drags whose `types` has
  `Files`. Drops go through the same `attach/1` as a paste, so limits and
  refusals are identical, and the upload goes through `uploadTo(<its form>)`.
  The nested-drag depth counter and the `updated/0` restore are covered in
  `test/js/comments_hooks_test.cjs`. `hidden` and `flex` both sit on the hint:
  the hook removes `hidden` rather than overriding it, so stylesheet order
  doesn't matter.
- **Catalogues.** The two new msgids are in the `.pot` and en/et/ru.

## Considered and left alone

- **NITPICK (not changed).** `moderation_allows?/3` checks list membership,
  and the rule keeps each type's uuids as a list because that list is also the
  SQL array parameter. For the guard that means each use costs O(n) in the
  handler's answer. Even a folder delete of hundreds of files against a
  70,000-uuid answer stays well inside core's 5 s guard timeout, so a `MapSet`
  copy isn't worth the extra shape.
- A commenter deleting their own file from the media page sees "not available
  to you" unless they moderate the record. This follows the "no own-comments
  exception" rule the moderation page also follows. It's consistent; noted in
  case it reads oddly in support.
