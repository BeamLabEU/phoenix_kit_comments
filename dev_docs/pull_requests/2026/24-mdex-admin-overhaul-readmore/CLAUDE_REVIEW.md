# PR #24 Review — MDEx rendering, comments admin overhaul, and Read-more truncation

- **Author:** Sasha Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/24
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-17 (review is post-hoc)
- **Diff size:** +642 / −245, 7 files; bump 0.2.9 → 0.2.10

## Summary

Three threads in one PR: (1) swap the comment-display markdown engine from
Earmark to **MDEx (comrak)** to match the Leaf composer, extracting a shared
`PhoenixKitComments.Web.Markdown` (`comment_markdown/1` + `comment_markdown_styles/1`);
(2) a broad **moderation-admin overhaul** of `/admin/comments` — i18n sweep,
navbar header, resource thumbnail chips, uuid-deep-link reply navigation,
status-aware `⋯` row-action menu, and a full-comment modal; and (3)
**long-comment truncation** — a one-line preview + "Read more" modal in the
admin, and a YouTube-style inline expand/collapse in the public component.

## Verdict

**Approve as merged**, with two follow-ups fixed directly on `main` (see
[Post-review fixes](#post-review-fixes)): a render-time crash on replies to
media-only comments, and an incomplete shared-styles extraction that left the
public component on a divergent inline CSS copy.

## What's good

- **Engine unification is the right call.** Rendering display markdown with the
  same engine and `render` options (`hardbreaks`, `unsafe`) the Leaf composer
  uses means the rendered comment matches what the author typed. Output still
  flows through core's `HtmlSanitizer`, so the `unsafe: true` is sanitized after
  the fact — XSS posture is unchanged.
- **`render_markdown/2` degrades safely.** Blank input → `""`; a parse `{:error,
  _}` falls back to HTML-escaped raw text rather than raising. Clauses cover
  `nil`, `""`, binary, and other.
- **uuid-aware search is well-guarded.** `list_all_comments` only treats the
  search term as an exact-uuid match when `Ecto.UUID.cast/1` succeeds, and still
  ORs in the content `ilike` — so a literal uuid typed into the box can't
  silently hide content matches, and non-uuid input takes the plain path.
- **Status-aware actions are coherent.** The `⋯` menu offers Restore-only for
  deleted comments and gates Approve/Hide on current status, matching the users
  table. Distinct menu ids per surface (table / card / modal) avoid DOM id
  collisions while both views are mounted.
- **Modal lifecycle is handled.** `load_comments/1` clears `:viewing_comment`, so
  any action/filter/navigation closes the modal rather than leaving stale
  content on screen. `view_comment` re-fetches with `preload: [:user]` instead of
  trusting the list row.
- **No queries in `mount`.** Data loading stays in `handle_params` →
  `load_comments`; `mount` only sets defaults. Consistent with the framework
  lifecycle.

## Findings

1. **(High — crash) `reply_indicator/1` raises on a reply to a media-only
   parent.** ✅ **Fixed** (see [Post-review fixes](#post-review-fixes)).
   `String.slice(@comment.parent.content, 0..39)` assumes the parent has text,
   but a comment's `content` is allowed to be `nil`/blank when it carries only a
   GIF or attachment (`Comment.do_validate_content_or_media/2`). `list_all_comments`
   preloads `:parent`, and the indicator renders whenever `@comment.parent` is
   set, so any reply whose parent is GIF/attachment-only hits
   `String.slice(nil, _)` and crashes the entire moderation LiveView render. The
   pre-PR code had the same unguarded slice; the PR refactored it into
   `reply_indicator` and carried the latent bug forward.

2. **(Medium — consistency / DRY) Shared-styles extraction is incomplete.**
   ✅ **Fixed** (see [Post-review fixes](#post-review-fixes)). The PR's stated
   goal was a shared `comment_markdown_styles/1` "used by the component and the
   admin." The admin renders it (`index.html.heex`), but the public
   `CommentsComponent` kept its **own inline `.pk-comment-md` `<style>` copy** —
   and the two had already drifted: `p { margin: 0.25rem }` vs `0.5rem` plus the
   `p:first/last-child` resets, heading top-margin `0.5rem` vs `0.75rem`, and a
   missing `pre` margin. So identical markdown rendered with different spacing on
   the two surfaces, with two sources of truth for the same CSS.

3. **(Low — efficiency) Previews render full markdown, then CSS-clamp to one
   line.** `comment_content_preview` calls `comment_markdown content={...}
   class="... line-clamp-1"`, so for every row the whole body is parsed to HTML
   and sanitized just to display one clamped line. Acceptable at moderation-page
   page sizes (≤ per_page rows) and avoids a separate plain-text path, so left
   as-is — but worth noting if list sizes grow or bodies get large.

4. **(Nit) `restore` maps to `approve_comment`, i.e. always → `published`.** A
   restored comment returns as `published` even if it was `pending` before
   deletion. Documented in the handler comment and a reasonable default for a
   moderation tool (an admin chose to restore it), so no change requested.

5. **(Nit) No render/LiveView tests.** The suite is purely context-level
   (`phoenix_kit_comments_test.exs`); there's no `ConnCase`/`LiveViewTest`
   harness, so finding #1's crash wasn't (and couldn't be) caught by tests.
   Consistent with the existing approach, so not a regression — but the markdown
   helpers and the status-aware menu logic are the kind of thing a lightweight
   render test would pin down cheaply.

## Post-review fixes

Applied directly to `main` after the post-hoc review:

- **Finding #1 — guarded the parent snippet.** Replaced the inline
  `String.slice(@comment.parent.content, 0..39)` with a `parent_snippet/1`
  helper: a `is_binary and != ""` head slices as before, and the fallback head
  returns a localized `[no text]` placeholder. Replies to GIF/attachment-only
  parents now render instead of crashing the page.
- **Finding #2 — unified the markdown styles.** The public component now imports
  and renders the shared `<.comment_markdown_styles />` (the same helper the
  admin uses) and its divergent inline `.pk-comment-md` block was removed
  (−~60 lines of duplicated CSS). The Giphy-picker styles stay inline. Admin and
  public now render identical markdown spacing from one source of truth.

`mix compile --warnings-as-errors` is green; the full suite (42 tests) passes.
Version left at 0.2.10 (bug/consistency fixes, no API change).

## Response to Kimi's review

Kimi's independent review (`KIMI_REVIEW.md` in this directory) raised seven
further items. After verifying each against the code, five were addressed on
`main`; two are noted below.

- **Kimi #1 — media-only comments invisible in admin preview/modal.** ✅ Fixed.
  Same root cause as my finding #1 (blank `content` for GIF/attachment-only
  comments). The list preview now shows a "GIF"/"Attachment" placeholder, and the
  full-comment modal renders the GIF (from `metadata`) plus an attachment count
  (`view_comment` now preloads `media: :file`).
- **Kimi #2 — inline `onerror` on the resource-chip thumbnail.** ✅ Fixed.
  Confirmed against `AGENTS.md` ("JavaScript hooks must be inline `<script>`
  tags; register on `window.PhoenixKitHooks`") — the inline handler also dies
  under a strict `script-src` CSP. Replaced the `<img onerror=…>` with a CSS
  `background-image` element, so a missing thumbnail falls back to the
  placeholder colour with no JS.
- **Kimi #3 — `navigate` for possibly-external resource URLs.** ✅ Fixed.
  Non-prefixed paths come from host-configured templates (controller pages or
  external URLs); they now use `href`. Prefixed (phoenix_kit LiveView) paths keep
  `navigate`. The existing `prefixed` flag distinguishes them, so no URL parsing
  is needed.
- **Kimi #4 — pagination links carry empty filter params.** ✅ Fixed. Pagination
  now reuses `build_url_params/2` (which strips blank values), matching the rest
  of the page.
- **Kimi #5 — clickable preview not keyboard-focusable.** ✅ Fixed. The preview
  is now `role="button"`, `tabindex="0"`, with `phx-keydown="view_comment"` /
  `phx-key="Enter"`.
- **Kimi #6 — card status as raw string, not a badge.** ⏸️ Not done. `card_fields`
  renders plain-text values by design (the core table card has no markup slot for
  field values); a badge would need restructuring the card. Cosmetic, low value —
  left as-is.
- **Kimi #7 — editing a comment to empty text fails even with media.** ⏸️ Noted,
  not done. Real, but pre-existing and on a different surface
  (`CommentsComponent.do_save_edit/2`, the public composer), not part of PR #24's
  display work. Worth a separate, focused change.

`mix compile --warnings-as-errors` green; 42 tests pass.

## Conclusion

A large but well-structured PR; the engine swap, uuid-deep-link search, and
status-aware moderation UI are correct and faithful to the existing admin
conventions. The two actionable items — a render crash on media-only-parent
replies (#1) and the half-finished shared-styles extraction (#2) — have been
fixed on `main`, completing the PR's own "shared markdown helper" intent and
closing the crash. Five of Kimi's seven follow-ups were also fixed (see above);
the remaining two are a cosmetic card-badge tweak and a pre-existing composer
bug. Approve as merged.
