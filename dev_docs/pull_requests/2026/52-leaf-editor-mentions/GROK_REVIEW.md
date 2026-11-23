# Grok Review — PR #52

**Reviewer:** Grok
**PR:** #52 "Add @ and # mentions to the rich (Leaf) comment editor" (alexdont)
**URL:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/52
**Reviewed:** 2026-11-23, against `main` since tag `v0.6.0`
**Verdict:** Approve. One low crash on a nil annotation URL, fixed. The
forward-path unescape hole is #53's merge, recorded there.

Reviewed against phoenix-thinking (LiveComponent `update/2`, no new
queries in `mount`) and elixir-thinking (one content boundary, pattern
matches on the editor kind).

## What landed

Leaf 0.11+ talks to the thread directly (`notify`). The component
unescapes visual-mode mention tokens, answers `@` / `#` from this
thread's editors only, and builds `comment_link/1` so a mention
notification opens on the comment. `with_annotation/2` moved here from
the moderation page so both callers share the uuid check.

As merged, the forwarded draft and reply assigns called
`unescape_mention_tokens/1` before storing the text. #53's merge
replaced that with `put_draft/2` and dropped the call. See
`../53-leaf-composer-mentions/GROK_REVIEW.md`.

## Findings

### 1. BUG - LOW — a file comment with no page crashed the annotation helper — FIXED

`with_annotation/2` appends `?annotation=` only after `Ecto.UUID.cast/1`.
The clause called `String.contains?(url, "?")` with no binary guard.
`ResourceLinks.url/1` returns `nil` when the resolved path is `nil` and
the info is not prefixed, and the moderation chip passes that straight
in, so rendering the row raised. `comment_link/1` rescues, so a
notification still goes out without a link. The same unguarded call
lived on the moderation page before this move (`link_with_annotation/2`
at v0.6.0); the move made it the shared helper.

**Fixed:** a non-binary URL does not enter the annotation clause. `nil`
stays `nil`. A value that is not a uuid is still left off the href.
`test/phoenix_kit_comments_test.exs`.

### 2. NITPICK — the old helper's comment was left above `status_badge_class/1` — FIXED

Moving the function deleted `link_with_annotation/2` and left its doc
comment in `index.ex`, now describing the status badge. Removed. The
uuid-cast reason sits on `with_annotation/2`.

## Checked, not re-filed

Claude's findings on this PR and #53 (suggestions only when Leaf has
`notify`, search under the event scope, warnings tied to the draft,
`:mention_warnings` kept out of the thread context) still hold in the
tree. `comment_link/1` keeps the `#pk-comment-` anchor, and
`Routes.local_path?/1` allows `?` and `#`, so core does not drop the
link. The jump hook stays scoped to the thread body.

## Other commits since v0.6.0

- `d2cafe5`, `e704b52`, `892979a` — lockfile only. `mix.exs` requirements
  are unchanged. No bump showed an obvious break. Not a dependency audit.
- `a321e90` — drops `Code.ensure_loaded?` probes for mentions,
  `User.display_name/1`, editor mode, and the removal-guard behaviour,
  matching the `>= 3.5.0` floor. Direct calls are consistent with that
  floor. No remaining probe the floor still needs.
