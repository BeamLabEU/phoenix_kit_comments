# PR #13 — Added file adding to be allowed in the comment

**Author:** alexdont (Sasha Don) | **Date:** 2026-05-11 | **Reviewer:** Claude
**State:** Merged as `e7302a6` into `main` (commit `50d2e0d`); H1+H2 follow-up applied 2026-05-11
**Stats:** +1,364 / −282 across 11 files

## Summary

Adds image / video / audio / generic-file attachments + in-browser voice recording to
comments, threaded through the parent `PhoenixKit.Modules.Storage` stack via a new
`phoenix_kit_comment_media` junction table. Three admin settings gate the feature
(`comments_attachments_enabled`, `comments_max_attachments`, `comments_attachment_max_size_mb`).
`create_comment/4` gains an `:attachment_file_uuids` option; insert + attaches run in one
transaction. Comment validity rule generalized from "content OR Giphy" to
"content OR Giphy OR attachments".

## Files Changed (11)

| File | Change |
|------|--------|
| `lib/phoenix_kit_comments.ex` | `attachments_enabled?/0`, `get_max_attachments/0`, `get_max_attachment_size_mb/0`; orchestrator `do_create_comment` with `attachment_file_uuids`; `attach_media/3`, `detach_media/2`, `detach_media_by_uuid/1`, `list_comment_media/2`; transactional `insert_comment_with_attachments` |
| `lib/phoenix_kit_comments/schemas/comment.ex` | Adds `has_many :media`, virtual `:has_attachments?`, `validate_content_or_media/1`, `ensure_content_not_nil/1` |
| `lib/phoenix_kit_comments/schemas/comment_media.ex` | New junction schema (`comment_uuid`, `file_uuid`, `position`, `caption`) |
| `lib/phoenix_kit_comments/web/comments_component.ex` | `allow_upload(:attachment, ...)`, attach-menu state, recorder events, `consume_attachments/1`, `render_attachment/1` per file_type |
| `lib/phoenix_kit_comments/web/comments_component.html.heex` | Inline `<script>` registering `PhoenixKitCommentsAudioRecorder` hook, attach-menu UI, staged-upload list, voice button |
| `lib/phoenix_kit_comments/web/settings.ex` | Adds 3 new allowed settings + numeric clamp ranges, reset-defaults entries |
| `lib/phoenix_kit_comments/web/settings.html.heex` | "Attachments" settings card |
| `lib/phoenix_kit_comments/web/index.ex` | Minor adjustments around moderation |
| `test/phoenix_kit_comments_test.exs` | `Comment.changeset` content/media validation tests + `CommentMedia.changeset` tests |
| `AGENTS.md` | Documents new schema + settings keys |
| `CHANGELOG.md` | Unreleased entry |

## ✅ Positives

- **Transactional insert.** `insert_comment_with_attachments/2` wraps `Comment.insert` + `attach_files` in one `Repo.transaction`; any media-attach failure rolls the comment back (`lib/phoenix_kit_comments.ex:378-387`). Good.
- **Belt-and-suspenders validation.** `allow_upload` enforces `max_entries` / `max_file_size` on the client side; `validate_attachments/1` re-checks count and UUID format server-side; `Comment.changeset` re-checks "content OR Giphy OR attachments" (`lib/phoenix_kit_comments.ex:400-417`, `lib/phoenix_kit_comments/schemas/comment.ex:132-148`).
- **Feature gated.** All three settings default to off / safe values; `attachments_enabled?/0` rescues exceptions so the form degrades silently when Settings isn't reachable.
- **Size cap clamped at read.** `get_max_attachment_size_mb/0` `min`s the comment cap against the global `storage_max_upload_size_mb`, so an admin can't accidentally let comments exceed the platform cap.
- **Media preloaded with correct order.** `has_many :media` declares `preload_order: [asc: :position]` (`comment.ex:77-80`); `get_comment_tree/2` uses `preload: [:user, media: :file]` — single query, no N+1.
- **Junction FK semantics are right.** `ON DELETE CASCADE` on `comment_uuid`, `ON DELETE RESTRICT` on `file_uuid` (file may be referenced by other comments/posts; storage GC sweeps orphans). Documented in `comment_media.ex` `@moduledoc`.
- **Per-file_type rendering.** `render_attachment/1` pattern-matches on `file.file_type` and emits semantic markup (`<img>` / `<video>` / `<audio>` / download link), with `signed_url(file, "medium" | "video_thumbnail" | "original")` variants.
- **Hook idempotency.** The inline `<script>` registers under a global `window.PhoenixKitHooks` registry and bails if the key exists, so multiple components on one page don't double-register.
- **`PostMedia` parity.** Schema and table layout mirror `PhoenixKitPosts.PostMedia` (per moduledoc), keeping a single mental model across the kit.
- **Tests added.** Changeset-level coverage for the new "content OR media" rule and `CommentMedia` requireds.

## ⚠️ Concerns

### H1 — Files are stored *before* server-side validation runs (Medium) — ✅ FIXED

`consume_attachments/1` in `comments_component.ex:439-468` calls
`PhoenixKit.Modules.Storage.store_file/2` for every entry *before* `create_comment/4` is
invoked. Inside `do_create_comment`, the validation chain runs *after* that:

```elixir
with :ok <- validate_depth(attrs),               # may fail
     :ok <- validate_content_length(attrs),      # may fail
     :ok <- validate_attachments(file_uuids),    # may fail
     :ok <- validate_has_body(attrs, file_uuids),
     {:ok, comment} <- insert_comment_with_attachments(...)
```

If depth is exceeded, content length is too long, or `attachments_enabled?` flipped to
`false` between mount and submit, the files are already in storage with no junction row.
The `CommentMedia` moduledoc says "the file is reaped by the storage GC pass" — fine
as a safety net, but you're burning upload bandwidth + storage cycles every time a user
hits one of those validation failures.

**Suggestion:** Move cheap pre-checks (`attachments_enabled?`, count cap, content length,
depth) ahead of `consume_uploaded_entries` in the LiveView. `consume_uploaded_entries`
is destructive — once you call it you've committed.

**Resolution (2026-05-11):** Added `PhoenixKitComments.precheck_create/5` that runs
`maybe_calculate_depth` + `validate_depth` + `validate_content_length` +
`validate_attachment_count` + `validate_has_body` against the staged entry count, with
zero side effects (no DB writes, no file I/O — only a parent-comment SELECT for depth).
Refactored `do_create_comment/4` to share the same validator chain via
`prepare_create_attrs/4` and `run_cheap_validators/2` so non-LiveView callers stay
covered. The component's `handle_event("add_comment", ...)` now calls
`precheck_create/5` first and only invokes `consume_attachments/1` on `:ok`. On failure
the upload entries remain staged on the socket — the user fixes the input and resubmits
without re-uploading. Errors mapped through `create_error_message/1` (no more
`inspect(reason)` leakage on `:max_depth_exceeded`/`:content_too_long`/etc.).

Touched: `lib/phoenix_kit_comments.ex` (precheck_create, prepare_create_attrs,
run_cheap_validators, validate_attachment_count, validate_file_uuid_format,
validate_has_body); `lib/phoenix_kit_comments/web/comments_component.ex` (split
add_comment handler, added create_error_message/1).

### H2 — `:has_attachments?` is publicly castable (Medium) — ✅ FIXED

```elixir
# schemas/comment.ex:101-113
cast(attrs, [..., :metadata, :has_attachments?])
```

```elixir
# schemas/comment.ex:140-146
has_attachments? = get_field(changeset, :has_attachments?) == true
cond do
  ...
  has_attachments? -> changeset
  true -> add_error(changeset, :content, "...")
end
```

Any caller of `update_comment/2` (or even `create_comment/4` when bypassing the
orchestrator) can pass `has_attachments?: true` in attrs and satisfy
`validate_content_or_media/1` without actually having media. The orchestrator does
`Map.put(attrs, :has_attachments?, file_uuids != [])` on create (`lib/phoenix_kit_comments.ex:360`),
so the create-path is safe — but `update_comment/2` passes attrs straight through, and
it's part of the public API.

**Suggestion:** drop `:has_attachments?` from `cast`, and in `validate_content_or_media/1`
either:
- consult the loaded `:media` association when present (cheap when the changeset wraps an
  already-preloaded record), or
- accept the boolean only via `put_change` from a private helper that the orchestrator calls.

Same applies to `update_comment/2` — if a user edits a comment whose media row gets
detached out of band, `validate_content_or_media` should be re-derived from current
state, not from an attr the caller controls.

**Resolution (2026-05-11):**

1. Removed the virtual `:has_attachments?` field from `Comment` entirely. It is no
   longer in `cast`, so callers cannot drive it via attrs.
2. `Comment.changeset/3` now takes an `opts \\ []` keyword list and resolves media
   presence in this order:
   - Explicit `has_media: bool` opt (only the orchestrator passes this on insert,
     because the new comment has no `uuid` yet and the `media` association isn't
     loaded), then
   - The loaded `:media` association on the existing struct (used by
     `update_comment/2`).
3. `update_comment/2` calls `ensure_media_loaded/1` so a bare struct from
   `get_comment/1` gets its media preloaded before the changeset runs.
4. `validate_content_or_media/2` now skips entirely on status-only updates (when
   `:content` and `:metadata` aren't in `changeset.changes` and the record is not
   inserting). This avoids forcing `bulk_update_status/2` and moderation paths
   (`approve_comment/1`, `hide_comment/1`) to preload `:media` just to re-prove an
   invariant the record was already validated against at insert time.
5. Added a regression test: passing `has_attachments?: true` in attrs is now ignored
   and the blank-content rule still fires (`test/phoenix_kit_comments_test.exs`).
   Replaced the old "virtual flag accepts blank content" test with one that uses the
   new `has_media: true` opt.

Touched: `lib/phoenix_kit_comments/schemas/comment.ex` (drop virtual field, new opts
on changeset, split `validate_content_or_media/2` + `do_validate_content_or_media/2` +
`resolve_has_media/2` + `infer_has_media/1`); `lib/phoenix_kit_comments.ex`
(`update_comment` preloads, orchestrator passes `has_media: file_uuids != []` to
`Comment.changeset/3`); `test/phoenix_kit_comments_test.exs` (new regression test).

All 32 tests pass; `mix format --check-formatted` clean.

### H3 — Inline `<script>` block in HEEx breaks strict CSP (Medium / depends on deployment)

`comments_component.html.heex:2-86` ships the `PhoenixKitCommentsAudioRecorder` hook as a
top-level `<script>` element inside the template. This is rendered every time the
component mounts, idempotency-guarded but inline.

- Strict CSP (`script-src 'self'`) will block this entirely; users will get a
  "Microphone access is not supported by this browser." message that's actually a
  blocked script, not a missing API.
- The hook isn't discoverable from `app.js`, which is where downstream projects look
  when wiring up Phoenix LiveView hooks.
- Inline `<style>` is in the same boat (lines 88-128).

**Suggestion:** ship the hook as a documented snippet (or a `priv/static` asset) that
the consuming project pulls into its `app.js` next to the other LiveView hooks. If you
keep it inline, document the CSP requirement in `AGENTS.md` / README. At minimum,
extract the `<style>` to `assets/css/` since it has no per-render state.

### M1 — `audio_recording_error` flash is client-controlled (Low)

`comments_component.ex:204-209` accepts an arbitrary `message` string from the JS client
and pushes it straight into the flash:

```elixir
def handle_event("audio_recording_error", %{"message" => message}, socket) do
  {:noreply, socket |> put_flash(:error, message)}
end
```

Flash content is normally escaped, so this isn't an XSS hole, but it lets a tampered
client populate the user's flash with arbitrary text (e.g., a phishy "Click here to
re-authenticate at evil.example.com"). Same shape lets a misbehaving extension or
DOM-rewriting userscript inject confusing error messages.

**Suggestion:** translate fixed codes server-side, e.g. send `%{"reason" => "permission_denied"}`
and map to a controlled string set. Drop unknown codes.

### M2 — Upload-error reason leaked verbatim to the user (Low)

```elixir
# comments_component.ex:464-465
{_, [{:error, reason} | _]} ->
  {:error, "Upload failed: #{inspect(reason)}"}
```

`reason` may be an Ecto.Changeset, a tuple, a struct from the storage layer — anything
the parent lib chooses to return. `inspect/1` will dump it (potentially including DB
column names, internal paths, file UUIDs) into a flash banner shown to end users.

**Suggestion:** keep a curated set of user-facing error strings; log `inspect(reason)`
server-side via `Logger.warning`.

### M3 — `allow_upload` constraints frozen at mount (Low)

`mount/1` reads `get_max_attachments/0` and `get_max_attachment_size_mb/0` once and
hands them to `allow_upload/3`. Subsequent admin setting changes don't take effect
until a fresh LiveView mount.

The server-side `validate_attachments/1` *does* re-check `attachments_enabled?` and the
current count cap on every create (good), so the worst-case staleness is "uploads
accepted by the client and then rejected by the server". Worth a sentence in the
`@moduledoc`.

### M4 — Tests don't cover the orchestrator transaction path (Low)

The new tests are pure changeset tests. There's no Repo-backed exercise of:
- `attach_files/2` rollback when a `file_uuid` doesn't exist
- `validate_attachments` with `attachments_enabled? == false`
- `insert_comment_with_attachments` preserving `position` ordering
- `attachment_file_uuids: []` short-circuiting through `insert_comment_with_attachments/2`'s
  arity-2-empty-list clause

If the project's test setup supports a Repo sandbox (the existing tests don't seem to —
they're all behaviour/metadata smoke tests), at least one integration spec would catch
regressions in the transaction boundary.

### M5 — Wide `accept` list for general files (Low)

`allow_upload(:attachment, accept: ~w(image/* video/* audio/* .pdf .doc .docx .txt .md .zip .rar .7z))`
(`comments_component.ex:74-84`). Accepting `.zip / .rar / .7z` opens the usual
phishing-attachment surface for any comment thread, e.g. a malicious user dropping a
password-stealing archive on a public post. Phoenix LiveView trusts the `accept`
filter client-side; the server doesn't re-validate MIME (see N1 below).

**Suggestion:** make the `accept` list a configurable setting (`comments_accept_extensions`)
with a conservative default, or at least document the security implication.

### M6 — `content_type` from `Plug.Upload` passed straight to storage (Low → depends on storage lib)

```elixir
# comments_component.ex:446-452
opts = [
  filename: entry.client_name,
  content_type: entry.client_type,  # <-- client-supplied
  ...
]
PhoenixKit.Modules.Storage.store_file(meta.path, opts)
```

Per Phoenix LiveView gotchas: `entry.client_type` is user-provided and shouldn't be
trusted for security decisions. If the storage layer sniffs magic bytes and overrides
this — fine. If it stores the value verbatim and uses it for the `Content-Type` header
on signed-URL responses, an attacker can upload `.exe` masquerading as `image/png` and
the browser will happily render the spoofed type. Recommend confirming with the
parent-lib team and documenting the contract here.

## Nits

- **N1 — `&bull;`** in `comments_component.ex:515`: `<span class="text-base-content/60 hidden sm:inline">&bull;</span>` — HEEx escapes by default, this renders the literal text `&bull;`, not a bullet. Use `{"•"}` or `<span>…</span>` content via interpolation. (Pre-existing line, surfaced again by the diff.)
- **N2 — `inspect(reason)` again** in `Logger.warning("Failed to load comment counts by type: #{inspect(e)}")` (`lib/phoenix_kit_comments.ex:693`): style nit — switch to `Logger.warning/2` with metadata to avoid string interpolation cost on disabled levels.
- **N3 — Magic constant**: `max_file_size: max_size_mb * 1024 * 1024` (`comments_component.ex:83`) — fine, but consider naming `@bytes_per_mb 1_048_576` for readability.
- **N4 — Unused `audio_recording_stopped`?** The recorder JS calls `pushEventTo(this.el, "audio_recording_stopped", {})` after `cleanup()`, but the comment form submit also explicitly sets `:recording_audio?` to `false` in the success branch of `add_comment` (`comments_component.ex:168`). Double-reset is fine, just two sources of truth.
- **N5 — `first_error_message/1`** formats `:has_attachments?` errors as "Has attachments? can't be …". Edge case (the validator doesn't emit on this field today), but the helper would humanize awkwardly.
- **N6 — JS hook lifecycle**: the recorder doesn't `cancel_upload` if the user cancels mid-recording before `stop()`. `cleanup()` releases the mic stream, but if `start()` succeeded and the page navigates, `destroyed()` calls `cleanup` only — never sends `audio_recording_stopped`, so the socket can be left with `:recording_audio? == true` if the user navigates away mid-record. Cosmetic; cleared on next mount.

## Verdict

**🟡 Approved (merged) with follow-ups for 0.1.6.**

The feature is well-architected and mirrors the existing `PostMedia` shape. Transactional
insert and FK semantics are correct, settings gating is sensible, and the moduledoc/AGENTS
docs are updated. The validator unit tests are a real (if small) improvement.

### Applied 2026-05-11

- ✅ **H1** — `precheck_create/5` runs before `consume_uploaded_entries`; failed
  validations no longer leak files into Storage. Error reasons mapped to friendly
  strings (so M2's `inspect(reason)` leak is partially addressed for known error atoms;
  storage-side surprises still surface raw).
- ✅ **H2** — Virtual `:has_attachments?` removed from `Comment`. `Comment.changeset/3`
  takes a `has_media:` opt (orchestrator-only) or falls back to the loaded `:media`
  association (`update_comment/2` preloads). Status-only updates skip the
  content-or-media check, keeping `bulk_update_status/2` cheap.
- ✅ Tests: 32 passing, including a new regression test that proves
  `has_attachments?: true` in attrs is now inert.

### Still open for 0.1.6

1. **Extract or document the inline `<script>` hook** (H3) — relevant to anyone running
   strict CSP, increasingly common.
2. **Sanitize the remaining error surface** (M1 `audio_recording_error`, M2 storage
   `inspect(reason)` path) — the known-atom error vocabulary is mapped now, but the
   `consume_attachments/1` storage failure still uses `inspect/1`.
3. **Add at least one Repo-backed integration spec** for the orchestrator transaction
   (M4) — the precheck refactor is unit-tested at the changeset level but the
   `attach_files` rollback path has no Repo coverage.
4. **Confirm storage-layer content-type handling** (M6) — likely already done in the
   parent lib, just worth a docstring line.
5. **Tighten the default `accept` list or make it configurable** (M5).

None of these are release-blockers given the feature is admin-off by default and the
parent storage layer handles deduplication / GC.
