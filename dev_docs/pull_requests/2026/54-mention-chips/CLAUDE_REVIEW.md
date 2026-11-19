# Claude Review — PR #54

**Reviewers:** Claude Opus 5.5, with codex (GPT-6.1), review and re-review
**PR:** Show a mentioned person as a chip with their face in a posted comment (mdon)
**Reviewed:** 2026-11-19

## Findings

### BUG - MEDIUM — a mention inside an attribute broke the attribute (fixed)
`[open](/help "@[user:…|A]")` or `[x](/people/@[user:…|A])`: the placeholder landed in `title`/`href`, and the chip's quotes broke the attribute open; the chip's fixed attributes landed on the writer's link (codex). No writer text was involved, so it was not XSS, but the link was corrupted. Placeholders are now judged in context: inside a tag, the escaped "@Name". Test: "in a link's address or title it is the plain name, the attribute intact".

### BUG - MEDIUM — chips inside code, a link's text and autolinks (fixed)
A chip inside `<code>`, inside the writer's link (nested anchors) and in an autolink's address and text (codex). Inside `a`/`code`/`pre` it is now the plain name. Test: "in a code span, a link's text or an autolink it is the plain name".

### BUG - LOW — a reference link labelled by a mention stopped linking (fixed)
The label and its definition got different placeholders (codex). Now one placeholder per distinct token. Test: "a reference link whose label is a mention still links".

### BUG - LOW — the chip broke out of the paragraph (fixed; found in the browser)
Core's avatar is two `<div>`s, so the browser closed the comment's `<p>`. They are now rendered as `<span>`s. Test: no `<div` inside the chip.

### NOT CHANGED — a name in a URL the writer wrote
A mention in the query of the writer's own link gives HTML-escaped "@Name", not URL-encoded (codex, re-review). The writer controls that link, and the attribute stays intact.

### PRE-EXISTING — linked images inside a link
The module's image pass can produce a link inside the writer's link (codex, re-review). It predates this change.

## Verification
464 tests, 0 failures; quality.ci clean; dev-box browser check of a posted mention.
