# Grok Review — PR #54

**Reviewer:** Grok
**PR:** #54 "Show a mentioned person as a chip with their face in a posted comment" (mdon)
**URL:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/54
**Reviewed:** 2026-11-23, against `main` since tag `v0.6.0`
**Verdict:** Approve. No new defect. The chip fixes already on `main`
still hold.

Reviewed against phoenix-thinking (chips are rendered in `update/2`,
not `mount`) and elixir-thinking (placeholder substitution versus
`Token.parse/1`).

## Findings

None new.

Claude's and Codex's findings (a chip inside an attribute, inside
`code` / a link / an autolink, a reference-link label, a `<div>` avatar
breaking the paragraph, a literal mention unescaped beside a real chip,
a non-user type sharing a uuid, punctuation in a query, initials taken
from the email) are fixed in the tree and covered by
`test/integration/mention_chips_test.exs`. The later commit `6406da6`
percent-encodes a mention that lands in `src` / `href` / `cite`.

## Checked, and not a bug

- `Regex.replace(Token.pattern(), content, fn raw -> … end)` is arity 1.
  The function receives the whole match, including a leading escape, so
  a literal mention is not in the placeholder map and stays literal.
  Confirmed under `mix run` against phoenix_kit 3.7.0. Chips are not
  silently skipped.
- `put_chips/2` can count a stray closer as a negative holder depth.
  `Markdown.render_markdown/1` runs ammonia first, and that strips or
  rebalances stray `</code>`, `</a>` and `</pre>` before the walk. No
  sanitizer output in this pass drove the counter negative, so it was
  not clamped.
- A chip asks `<.user_avatar>` only when `avatar_file_uuid` is set, and
  that branch prefers the stored file. The no-file branch draws initials
  from the resolved title. Readers do not contact Gravatar or an OAuth
  host. That is the intended split from core's `MentionText`.
- User paths from `ResourceLinks` are raw and forced `prefixed: true`,
  so `Routes.path/1` on the chip does not double-prefix.

## Left as they are

- The moderation page still renders bodies with `comment_markdown/1`,
  which does not run chips or `to_markdown/2`. That predates this PR.
  Changing the moderation thread is a separate piece of work.
- `Mentions.notify/2` still quotes `comment.content`. The `link:` option
  added in #52 did not introduce that.
