# Changelog

## 0.1.6 - 2026-04-17

### Fixed

- Drop `Application.put_env(:giphy_api, :api_key, ...)` in
  `PhoenixKitComments.search_giphy/2`. The key is now passed per-call via
  `giphy_api` 0.1.1's new `:api_key` option — no more global write on each
  search. Also guards against empty API keys at the wrapper level.

### Dependencies

- Bump `giphy_api` from `~> 0.1` to `~> 0.1.1`.

## 0.1.5 - 2026-04-16

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

### Breaking

- `Comment.changeset/2` no longer requires `:content`; either `content` or a GIF
  attachment in `metadata["giphy"]` is accepted. Downstream consumers that built
  their own changeset relying on the `content can't be blank` error should check
  the new validation path.

## 0.1.4 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md


All notable changes to PhoenixKitComments will be documented in this file.

## Unreleased

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
