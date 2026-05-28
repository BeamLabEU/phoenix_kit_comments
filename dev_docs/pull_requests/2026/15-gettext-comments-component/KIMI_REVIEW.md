# Kimi Review — PR #15

**Reviewer:** Kimi Code CLI  
**PR:** Wrap user-facing CommentsComponent strings in gettext  
**Author:** Max Don (mdon)  
**Date:** 2026-05-14  
**Status:** Merged

## Overall Assessment

**Verdict: APPROVE — solid i18n foundation, follow-up completed in-session for flash/JS strings**

Focused, low-risk PR that wraps ~27 rendered UI strings in the public comment thread with `gettext(...)`. No behavior changes, correct use of the shared `PhoenixKitWeb.Gettext` backend, and good use of named interpolation for dynamic msgids. The companion manifest approach in `phoenix_kit` PR #542 is the right call since `mix gettext.extract` only walks core's `lib/`.

**Risk Level:** Low — string-only change, no logic or data model modifications.

---

## Critical Issues

*(None)*

---

## High Issues

*(None)*

---

## Medium Issues

### 1. BUG - MEDIUM: `alt="GIF"` in `render_comment` remains untranslated

**File:** `lib/phoenix_kit_comments/web/comments_component.ex` (line ~625)

The `alt` attribute on the rendered Giphy image inside `render_comment/1` is hard-coded as `"GIF"`. Screen readers will announce this in English regardless of locale.

**Fix:**
```elixir
alt={gettext("GIF")}
```

-- FIXED

---

### 2. BUG - MEDIUM: Flash and error-helper strings in `.ex` file remain untranslated

**File:** `lib/phoenix_kit_comments/web/comments_component.ex`

While the PR covers rendered template strings, ~20+ user-facing flash/error strings in the live-component callbacks and helpers are still raw English. These show up as toast notifications and inline errors, so they are just as visible to end users as the template text.

Examples:
- Flash: `"Sign in to post a comment"`, `"Comment not found"`, `"Comment added"`, `"Comment deleted"`, `"You don't have permission to edit this comment"`, etc.
- `create_error_message/1`: `"Comment can't be empty"`, `"Attachments are disabled"`, `"Reply nesting is too deep"`, `"Up to #{...} attachments per comment"`, etc.
- `upload_error_label/1`: `"File too large"`, `"Too many files"`, `"File type not allowed"`, `"Upload error: ..."`

**Fix:** Wrap all of these in `gettext(...)` (and `gettext(..., ...)` for the interpolated ones). Since the module already has the Gettext backend available via `use PhoenixKitWeb, :live_component`, this is a straightforward follow-up.

-- FIXED

---

## Low Issues / Nitpicks

### 3. NITPICK: Edit button (pencil icon) lacks accessible label

**File:** `lib/phoenix_kit_comments/web/comments_component.ex` (line ~568)

The edit button contains only an icon with no text or `aria-label`. Since the PR is improving accessibility via i18n, adding `aria-label={gettext("Edit comment")}` would close the gap.

-- FIXED

---

### 4. OBSERVATION: Inline JavaScript error strings are untranslated

**File:** `lib/phoenix_kit_comments/web/comments_component.html.heex` (lines ~23–65)

The audio-recorder hook pushes English error messages (`"Microphone access is not supported by this browser."`, `"Microphone permission denied."`, etc.) via the `audio_recording_error` event, which end up in flash toasts. Internationalizing inline `<script>` tags is harder (requires passing a locale dictionary or using `data-*` attributes), but worth noting as a follow-up item since these strings are user-visible.

---

### 5. OBSERVATION: Default section title `"Comments"` is untranslated

**File:** `lib/phoenix_kit_comments/web/comments_component.ex` (line ~96)

`assign_new(:title, fn -> "Comments" end)` uses a raw English default. Parent LiveViews can and should override this, but wrapping the default in `gettext("Comments")` would make the component fully self-contained for i18n.

-- FIXED

---

## What Was Done Well

1. **Focused scope** — The PR touches only user-facing HEEx strings and the `render_comment` inline template. No logic drift.
2. **Correct interpolation** — Dynamic msgids (`Remove %{name}`, `Up to %{count} files, max %{size}MB each`, `Select GIF %{id}`) use named `gettext` bindings, which are translator-friendly.
3. **Shared backend** — Uses `PhoenixKitWeb.Gettext` correctly; no new Gettext module introduced in this library.
4. **Companion manifest strategy** — Acknowledges the extraction limitation (`mix gettext.extract` walks core's `lib/` only) and coordinates with `phoenix_kit` PR #542 instead of trying to hack around it.
5. **Admin settings excluded** — Consistent with the legal-manifest precedent; admin UI stays in English intentionally.
6. **Clean diff** — No formatting noise, no unrelated changes.

---

## Priority Summary

| Priority | Issue | Status |
|----------|-------|--------|
| Medium | #1 `alt="GIF"` untranslated in `render_comment` | -- FIXED |
| Medium | #2 Flash/error strings in `.ex` remain untranslated | -- FIXED |
| Low | #3 Edit button missing `aria-label` | -- FIXED |
| Low | #4 JS error strings untranslated | Observation |
| Low | #5 Default `"Comments"` title untranslated | -- FIXED |
