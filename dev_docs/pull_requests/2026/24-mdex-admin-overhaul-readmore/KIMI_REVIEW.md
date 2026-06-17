# PR #24 Review — MDEx rendering, comments admin overhaul, and Read-more truncation

- **Author:** Sasha Don (`alexdont`)
- **Reviewer:** Kimi
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/24
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-17; post-hoc review
- **Diff size:** +642 / −245, 7 files; bump 0.2.9 → 0.2.10

## Summary

Three threads in one PR: (1) swap the comment-display markdown engine from Earmark to **MDEx (comrak)** to match the Leaf composer, extracting a shared `PhoenixKitComments.Web.Markdown` (`comment_markdown/1` + `comment_markdown_styles/1`); (2) a broad **moderation-admin overhaul** of `/admin/comments` — i18n sweep, navbar header, resource thumbnail chips, uuid-deep-link reply navigation, status-aware `⋯` row-action menu, and a full-comment modal; and (3) **long-comment truncation** — a one-line preview + "Read more" modal in the admin, and a YouTube-style inline expand/collapse in the public component.

Claude's post-hoc review (see `CLAUDE_REVIEW.md` in this directory) already caught and fixed two issues directly on `main`: a render crash on replies to media-only parent comments, and an incomplete shared-styles extraction that left the public component on a divergent inline CSS copy. This review covers additional gaps found in the merged code.

## Verdict

**Approve as merged**, with several follow-ups noted below. The remaining issues are UX/convention gaps rather than correctness bugs; none block the PR's core intent.

## What's good

- **Engine unification is the right call.** Rendering display markdown with the same engine and `render` options (`hardbreaks`, `unsafe`) the Leaf composer uses means the rendered comment matches what the author typed. Output still flows through core's `HtmlSanitizer`, so the `unsafe: true` is sanitized after the fact — XSS posture is unchanged.
- **`render_markdown/2` degrades safely.** Blank input → `""`; a parse `{:error, _}` falls back to HTML-escaped raw text rather than raising. Clauses cover `nil`, `""`, binary, and other.
- **uuid-aware search is well-guarded.** `list_all_comments` only treats the search term as an exact-uuid match when `Ecto.UUID.cast/1` succeeds, and still ORs in the content `ilike` — so a literal uuid typed into the box can't silently hide content matches, and non-uuid input takes the plain path.
- **Status-aware actions are coherent.** The `⋯` menu offers Restore-only for deleted comments and gates Approve/Hide on current status, matching the users table. Distinct menu ids per surface (table / card / modal) avoid DOM id collisions while both views are mounted.
- **Modal lifecycle is handled.** `load_comments/1` clears `:viewing_comment`, so any action/filter/navigation closes the modal rather than leaving stale content on screen. `view_comment` re-fetches with `preload: [:user]` instead of trusting the list row.
- **No queries in `mount`.** Data loading stays in `handle_params` → `load_comments`; `mount` only sets defaults. Consistent with the framework lifecycle.

## Findings

1. **(Medium — UX/functional) Media/GIF-only comments are invisible in the admin preview and modal.**
   The admin preview only renders `comment_markdown content={@comment.content}`, and the full-comment modal only renders `<.comment_markdown content={@viewing_comment.content} />`. Because the schema explicitly allows comments with no text when they carry a GIF or attachment (`Comment.do_validate_content_or_media/2`), such comments produce an empty one-line preview and an empty modal. The public component renders GIFs and attachments; the admin now shows nothing for the same comment. A media-only row appears blank except for the author/resource chip, and clicking it opens a modal with no body.

   **Suggested fix:** render a placeholder in the preview for media-only rows (e.g. "GIF", "1 attachment") and include the existing GIF/attachment rendering in the modal body.

2. **(Medium — CSP/convention) Resource chip thumbnail uses an inline `onerror` handler.**
   `resource_chip/1` in `lib/phoenix_kit_comments/web/index.ex` renders `<img onerror="this.style.display='none'" ... />`. `AGENTS.md` requires JavaScript hooks to be inline `<script>` tags registered on `window.PhoenixKitHooks`. Inline event handlers are blocked by a strict `script-src` CSP and are inconsistent with the audio-recorder hook pattern used elsewhere in the same component.

   **Suggested fix:** either handle the missing image with a CSS-only fallback (background + generic icon) or register a small `PhoenixKitComments.ResourceThumbError` hook.

3. **(Medium/Low — correctness) Resource chip links may break for external URLs.**
   `resource_chip/1` uses `<.link navigate={resource_url(@comment, @info)}>`. `navigate` is intended for internal LiveView navigation. Path templates can in theory be full external URLs, in which case the link should use `href`, not `navigate`.

   **Suggested fix:** branch on whether the resolved URL is external and render `<.link href={...}>` for external URLs.

4. **(Low — UX/URL hygiene) Pagination links carry empty filter params.**
   The pagination links in `index.html.heex` build the URL with `URI.encode_query(%{"page" => page, "search" => @search || "", "resource_type" => @filter_resource_type || "", "status" => @filter_status || ""})`, producing URLs like `/admin/comments?page=2&search=&resource_type=&status=`. Functional, but inconsistent with `build_url_params/2` in `index.ex`, which strips empty values.

   **Suggested fix:** reuse `build_url_params` for pagination, or strip empty values before encoding.

5. **(Low — accessibility) Clickable comment preview is not keyboard-focusable.**
   `comment_content_preview/1` renders a `<div phx-click="view_comment">`. It has no `role="button"`, `tabindex`, or keyboard handler, so keyboard users cannot open the full-comment modal.

   **Suggested fix:** add `role="button"`, `tabindex="0"`, and a `phx-keydown` handler for Enter/Space.

6. **(Low — consistency) Card view status shows a raw string instead of a badge.**
   The `card_fields` block returns `%{label: gettext("Status"), value: comment.status}` as plain text, while the table view uses `status_badge_class/1`. Minor visual inconsistency between grid and table views.

   **Suggested fix:** render the status badge in the card using the same `status_badge_class/1` helper.

7. **(Observation — pre-existing) Editing a comment to empty text fails even if it has media.**
   In `CommentsComponent.do_save_edit/2`, `content == ""` returns an error flash before reaching the changeset. The changeset would accept an empty-content edit if the comment still has a GIF or attachment (because `update_comment/2` preloads `:media`), but the component rejects it unconditionally. Not introduced by PR #24, but worth fixing while the component is being touched.

## Conclusion

PR #24 is a well-structured, large change that successfully unifies markdown rendering and modernizes the admin moderation UI. The two issues Claude already fixed on `main` were the only crash/DRY blockers. The remaining items above are UX/convention follow-ups that should be addressed before the next release if time permits. Approve as merged.
