# Changelog

All notable changes to PhoenixKitComments will be documented in this file.

## 0.2.7 — Unreleased

### Changed

- `leaf` is now a required dependency (was `optional: true`). The comment
  composer is built on the Leaf editor, and phoenix_kit core already
  hard-depends on leaf, so it's always present wherever comments runs — the
  optional declaration described an unreachable leaf-free build. The
  `leaf_available?/0` textarea fallback stays as defensive code.

### Fixed

- `CommentsComponent` no longer flips to "Sign in to post a comment" for a
  logged-in user on a partial `send_update`. `can_post?` was derived from
  the incoming `assigns[:current_user]` (nil on any update that omits it,
  e.g. a parent poking `loaded?: false` to refresh the thread — as
  PhoenixKit's MediaCanvasViewer does when an annotation is drawn). It now
  reads the resolved socket value (kept across updates by `assign_new`),
  so the composer stays available.

## 0.2.6 — 2026-06-07

### Features

- New `PhoenixKitComments.Embed` macro. A host LiveView embedding
  `CommentsComponent` must forward the composer's rich-text (Leaf)
  `{:leaf_changed, …}` process message into
  `CommentsComponent.forward_leaf_event/2`, or the editor's content never
  reaches the component and "Post comment" silently no-ops. `use
  PhoenixKitComments.Embed` wires that forward as an `on_mount`
  `attach_hook(:handle_info)` lifecycle hook, so it composes with a host that
  already defines its own `handle_info` (no clause-grouping clash, no
  clobbering). For hosts that hard-depend on `phoenix_kit_comments`;
  soft-dependency hosts resolve `forward_leaf_event/2` at runtime instead (see
  the moduledoc).

### Changed

- Bumped dependencies (`mix.lock`).

## 0.2.5 — 2026-05-29

First Hex release since 0.2.1; bundles the unreleased 0.2.2–0.2.4 work
below plus the fixes and cleanup in this entry.

### Fixed

- Likes/dislikes no longer crash. `insert_reaction/2` had been switched to
  `insert_all` with `on_conflict: :nothing,
  conflict_target: [:comment_uuid, :user_uuid]`, but no composite unique
  index exists on those columns (the original `UNIQUE(comment_id,
  user_id)` was dropped with the integer `user_id` column during the
  uuid-FK migration and never recreated on `user_uuid`). That made every
  like/dislike raise a Postgrex "no unique or exclusion constraint
  matching the ON CONFLICT specification" error. Restored the
  `exists?`-precheck + changeset insert, which doesn't depend on the
  missing index.

### Changed

- Reaction highlight state (`liked_comment_uuids` /
  `disliked_comment_uuids`) is now reloaded only when comments reload or
  the viewer / `show_likes` change, instead of on every `update/2` —
  removing two redundant queries per parent re-render.
- The inline reply composer is no longer a feature-poor duplicate of the
  top/bottom composer. Both now share one `composer_form/1`, so replies
  gain the GIF picker, audio recorder, and full attach menu, and the form
  markup / translations live in a single place.
- Wrapped the remaining user-facing strings in the edit and reply forms
  in `gettext` (they had been missed in the gettext sweep).

## 0.2.4 — 2026-05-29

### Features

- Header is now configurable via three optional, backward-compatible
  assigns (defaults reproduce current behavior exactly):
  - `show_title` (default `true`) — when `false`, the
    "{title} ({count})" header line is not rendered.
  - `collapsible` (default `false`) — turns the header into a
    disclosure toggle (chevron + `aria-expanded`/`aria-controls`) that
    collapses/expands the whole body. Collapse state is ephemeral
    (in-memory, resets on remount).
  - `initial_collapsed` (default `false`) — starting collapse state when
    `collapsible`; host-customizable.
  Note: the collapse chevron lives in the header, so `collapsible` has
  no visible toggle when `show_title: false` (the thread stays per
  `initial_collapsed`).
- `composer_position` (default `:top`) — render the "Write comment"
  composer at `:top`, `:bottom`, or `:both`. Bottom is off by default.
  Internally the composer's open state is now position-aware
  (`composer_open_at`), so `:both` never mounts two Leaf editors or two
  upload inputs — only the opened position shows the form; the other
  stays a button.

## 0.2.3 — 2026-05-29

### Changed

- Comment card layout restructured to a strict vertical stack
  (avatar + email → decoration label → body → date → actions) so the
  card reads correctly in narrow embed containers (media sidebar,
  MediaDetail panel) instead of truncating the email under the action
  buttons.
- Action buttons (like / dislike / reply / edit / delete) are now
  right-aligned in their footer row.
- Decoration label (annotation title) now renders at the comment body's
  size, bold (`text-base font-bold`) — and gets top spacing so it reads
  as a peer title rather than a cramped sub-heading.
- Image attachments fill the comment width (`w-full max-h-96
  object-contain`) instead of being capped at `max-w-xs`.
- Bump leaf 0.2.13 → 0.2.21.

### Merged

- Integrated upstream `main` (gettext sweep + `precheck_create` upload
  refactor) with the local Leaf-editor, decoration-registry, inline-reply,
  reaction, and composer-toggle work.

## 0.2.2 — 2026-05-14

### Fixed

- Complete gettext/i18n coverage for `CommentsComponent` flash messages,
  error helpers, upload labels, video/audio fallback text, and accessibility
  attributes (`alt`, `aria-label`).
- Version sync between `mix.exs`, `version/0`, and test assertion.
- Precommit cleanliness: removed stale self-referential `phoenix_kit_comments`
  from `mix.lock`, formatted `mix.exs`.

## 0.2.1 — 2026-05-12

### Features

- Rendered comments now carry `data-comment-uuid` and (when present)
  `data-annotation-uuid` on the outer wrapper, letting sibling components
  on the host page correlate DOM nodes with comment + linked-resource
  uuids without reaching into render internals.
  `data-annotation-uuid` is sourced from `metadata["annotation_uuid"]`
  and omitted when nil.

## 0.2.0 — 2026-05-11

### Features

- **Comment attachments**: comments can now carry images, video, audio, and
  miscellaneous file uploads alongside text or a Giphy GIF. Attachments
  flow through the parent `PhoenixKit.Modules.Storage` stack (multi-bucket
  redundancy, variant generation) and link to comments via a new
  `phoenix_kit_comment_media` junction table.
- **In-browser voice recording**: a microphone button on the comment form
  records via `MediaRecorder` (webm/opus) and submits the result through
  the same upload queue as drag-and-drop attachments. Recordings are
  audio attachments — no separate code path.
- Three new admin settings under `/admin/settings/comments` →
  "Attachments":
  - `comments_attachments_enabled` (master toggle, default off)
  - `comments_max_attachments` (per-comment cap, 1–10, default 4)
  - `comments_attachment_max_size_mb` (per-file size cap, 1–500,
    clamped against the global `storage_max_upload_size_mb`)
- `create_comment/4` accepts a new `:attachment_file_uuids` key — a list
  of `PhoenixKit.Modules.Storage.File` UUIDs to attach in display order.
  Insert + attaches run in one transaction.
- New public context fns: `attach_media/3`, `detach_media/2`,
  `detach_media_by_uuid/1`, `list_comment_media/2`,
  `attachments_enabled?/0`, `get_max_attachments/0`,
  `get_max_attachment_size_mb/0`.
- Comment validity rule generalized to "content **OR** Giphy **OR**
  attachments". The Comment schema gains a virtual `:has_attachments?`
  field set by the orchestrator at insert time.

### Migration

- Requires the new `phoenix_kit_comment_media` table introduced in
  PhoenixKit migration V113. Run `mix ecto.migrate` after bumping the
  parent `phoenix_kit` dep.

## 0.1.5 — 2026-04-17

### Features

- Optional Giphy integration for the comment form. Users can post text-only,
  GIF-only, or text + GIF comments via a floating Giphy picker; the selected GIF
  is stored on `comment.metadata["giphy"]` and rendered inline with the comment.
- New admin settings under `/admin/settings/comments` → "Giphy Integration":
  enable toggle, API key (stored in DB), and content rating filter (G/PG/PG-13/R).
- `:form_extras` slot on `CommentsComponent` — parent projects can inject their
  own inputs into the new-comment form and any `name="metadata[<key>]"` values
  are merged into `comment.metadata` on submit (the `"giphy"` key is reserved).
- Character counter and Cancel button added to the top-level comment form.
- Responsive mobile overhaul of the entire comments component (down to ~320px):
  card `overflow-hidden`, wrapping header, `break-words` content,
  container-scaled GIFs, and a mobile bottom-sheet variant of the picker.

### Breaking

- `Comment.changeset/2` no longer requires `:content`; either `content` or a GIF
  attachment in `metadata["giphy"]` is accepted. Downstream consumers that built
  their own changeset relying on the `content can't be blank` error should check
  the new validation path.

### Dependencies

- Add `giphy_api ~> 0.1.1`. The API key is passed per-call via the library's
  `:api_key` option, so no global `Application.put_env/3` write happens on each
  search. Empty keys short-circuit before any HTTP call.

## 0.1.4 — 2026-04-12

### Fixed

- Add routing anti-pattern warning to AGENTS.md.

## 0.1.3 — 2026-04-02

### Improvements

- Migrate select elements to daisyUI 5 label wrapper pattern and remove deprecated
  `select-bordered` class.
- Mobile-responsive admin filter bar with separate mobile/desktop layouts.

## 0.1.2 — 2026-03-31

### Features

- Truncate long metadata values in display titles — individual values capped at 15 characters
  with `...` suffix to keep titles compact.
- Mobile-responsive settings page — table switches to stacked card view on small screens, toggles
  and buttons stack vertically, overflow prevention throughout.
- Client-side badge coloring — metadata field badges now highlight based on the currently focused
  input via the JS hook instead of server-side rendering.
- Display title shown in mobile card view on comments admin page when a display template is
  configured for the resource type.

## 0.1.1 — 2026-03-31

### Features

- Add `:prefix` placeholder for resource path templates — paths no longer auto-prefix with
  `Routes.path()`; include `:prefix` in your template to get the site URL prefix.
- Add configurable display title templates for resource types — show meaningful names instead of
  truncated UUIDs in the admin comment list.
- Add inline editing for resource link patterns in settings (edit button, save/cancel).
- Add inline comment content editing in CommentsComponent (edit button, save/cancel).
- Add clickable metadata field badges with live color updates — green when used in the template,
  gray when unused. Clicking inserts the placeholder at cursor position.
- Add `list_metadata_keys_by_type/0` — queries distinct JSONB metadata keys per resource type
  for display in settings.

### Bug Fixes

- Fix placeholder collision — `:metadata.prefix` and `:metadata.uuid` were corrupted by naive
  substring replacement. Metadata placeholders are now resolved first.
- Fix event listener accumulation in InsertAtCursor JS hook — listeners were re-added on every
  LiveView patch without cleanup. Now uses `AbortController` for proper teardown.
- Fix XSS vector in InsertAtCursor hook — replaced `querySelector` built from input name string
  with direct element reference.
- Fix missing server-side content validation on comment edits — now enforces empty check and
  configurable `comments_max_length` setting (previously only enforced on creation).
- Fix edit/reply state collision in CommentsComponent — entering edit mode now clears reply state
  and vice versa.
- Fix `editing_path_value` not cleared after saving resource path edit.
- Fix draft state (`draft_paths`/`draft_titles`) not cleaned up after adding unconfigured type.
- Add `Logger.warning` to `list_metadata_keys_by_type/0` rescue block instead of silently
  swallowing errors.
- Fix nested forms in settings page — Resource Link Patterns card was rendered inside the main
  settings `<form>`, producing invalid HTML. Moved outside the form.
- Fix stale assigns after adding/removing resource path templates — `unconfigured_types` now
  stays in sync without requiring a page refresh.
- Add path template input validation — templates must start with `/` or `:prefix` and cannot
  contain `://`, preventing XSS via `javascript:` URIs and open redirects.
- Add `Logger.warning` to rescue blocks in `count_comments_by_type/0` and
  `get_resource_path_templates/0` instead of silently swallowing errors.

### Improvements

- Deduplicate resource path add/save logic into shared `save_resource_config/5`.
- Make `extract_path/1` and `extract_title/1` private (only used within settings module).
- Resource path table uses `table-fixed` with `break-all` to handle long templates.

## 0.1.0 — 2026-03-27

### Features

- Initial release — polymorphic comments module extracted from PhoenixKit.
- Resource-agnostic design via `(resource_type, resource_uuid)` tuples with no FK constraints.
- Unlimited self-referencing comment threading with configurable max depth.
- Like/dislike system with denormalized counters and transactional safety.
- Moderation workflow: pending, published, hidden, deleted statuses with bulk operations.
- Admin UI: paginated comment list with search, status filters, and resource type grouping.
- Settings UI: toggles for enable/moderation, configurable max depth and max length.
- Resource handler callbacks for `on_comment_created/3` and `on_comment_deleted/3`.
- Resource resolution system with handler-based and path-template-based fallbacks.
- ILIKE search with proper wildcard escaping.
- Soft delete preserving comment tree structure.
