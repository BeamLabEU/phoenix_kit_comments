# Claude Review — PR #8

**Reviewer:** Claude Opus 4.6
**PR:** Add full untruncated title as tooltip on resource display links
**Author:** Sasha Don (alexdont)
**Date:** 2026-03-31
**Status:** Open

## Overall Assessment

**Verdict: APPROVE with minor cleanup needed**

Small, focused PR that adds a `full_title` field (untruncated) to the resource context map so the admin dashboard can show the complete title as a browser tooltip on hover. Good UX improvement for admins dealing with long resource names.

**Risk Level:** Low — display-only change, no data model or behavior modifications.

---

## Critical Issues

*(None)*

---

## High Issues

*(None)*

---

## Medium Issues

### 1. BUG - MEDIUM: Dead Code — Old Template Clauses Become Unreachable

**File:** `lib/phoenix_kit_comments/web/index.html.heex`

The two new `case` clauses matching `%{title: title, full_title: full_title, path: path, prefixed: true}` and `%{title: title, full_title: full_title, path: path}` are placed **before** the existing clauses. Since `resolve_via_path_template` now always includes `full_title` in the map, the new clauses will always match first, making the two original clauses (matching only `title` + `path`) dead code for template-resolved resources.

**Fix:** Replace the old clauses with the new ones instead of adding duplicates above them. The old clauses without `full_title` are only still needed if handler-resolved resources (which don't have `full_title`) need to match — but those already work via the existing clauses. So the simplest fix is to remove the old clauses entirely.

### 2. BUG - MEDIUM: `resolve_full_title` Duplicates `resolve_title` Logic

**File:** `lib/phoenix_kit_comments.ex`

`resolve_full_title/4` is a near-copy of `resolve_title/4` with truncation removed. Both run the same regex replacement over metadata. This means every comment now runs the metadata regex twice.

**Fix:** Resolve the full title once, then derive the truncated display title from it:

```elixir
full_title = resolve_full_title(title_template, resource_type, comment, metadata)
title = truncate_title(full_title)
{comment.resource_uuid, %{title: title, full_title: full_title, path: path, prefixed: false}}
```

This eliminates the duplication and ensures the two values can never diverge.

---

## Low Issues / Nitpicks

### 3. NITPICK: Handler-Resolved Resources Don't Get Tooltips

**File:** `lib/phoenix_kit_comments.ex` — `resolve_for_type/2`

The `resolve_via_handler` path (line 556) returns maps from external modules (e.g., `PhoenixKitPosts`) and adds `:prefixed` but not `:full_title`. These resources won't get tooltip behavior. This is fine for now since handlers control their own title format, but worth noting if tooltip coverage is expected to be universal.

### 4. OBSERVATION: Double Truncation in Template

**File:** `lib/phoenix_kit_comments/web/index.html.heex`

The template applies `String.slice(title, 0..49)` for display. The existing `title` value is already truncated by `apply_title_template` (metadata capped at 15 chars, UUID truncated). The `String.slice` is a second truncation pass. Not a bug — it's a safety net — but with the refactor suggested in #2, the truncated title could be derived with a single consistent limit.

---

## What Was Done Well

1. **Minimal, focused change** — Two files touched, clear purpose, no scope creep.
2. **Correct use of HTML `title` attribute** — Native browser tooltip is the right choice here; no JavaScript needed, works everywhere.
3. **Pattern matching ordering** — New clauses correctly placed before old ones so `full_title` maps match first (even though this makes the old ones dead code, the intent is correct).
4. **Nil-safe fallback** — `resolve_full_title(nil, ...)` correctly falls back to `"#{resource_type} #{comment.resource_uuid}"` with full UUID, matching the pattern from `resolve_title`.

---

## Priority Summary

| Priority | Issue | Status |
|----------|-------|--------|
| Medium | #1 Dead code — old template clauses unreachable | Open |
| Medium | #2 Duplicated `resolve_full_title` / `resolve_title` logic | Open |
| Low | #3 Handler-resolved resources don't get tooltips | Observation |
| Low | #4 Double truncation in template | Observation |
