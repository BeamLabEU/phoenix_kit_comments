# Grok Review — PR #53

**Reviewer:** Grok
**PR:** #53 "Fix the Leaf comment composer offering no @ or # mentions" (mdon)
**URL:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/53
**Reviewed:** 2026-11-23, against `main` since tag `v0.6.0`
**Verdict:** Approve after one fix. The merge kept #52's notify route
and #53's host attrs, and dropped unescape on the forwarded draft.

Reviewed against phoenix-thinking (LiveComponent `update/2` is the
content boundary for a host that forwards Leaf) and elixir-thinking
(the two editor paths have to apply the same token repair).

## Findings

### 1. BUG - MEDIUM — a forwarded draft or reply kept visual-mode escapes — FIXED

#52 stored forwarded draft and reply text through
`unescape_mention_tokens/1`. This merge sends that text through
`put_draft/2` so the host's `mention_warning` can run, and the call
stopped unescaping. The notify path (`handle_leaf/2`) and the forwarded
edit assign still unescape.

Leaf's visual mode writes `@\[user:…|Ada]` back from HTML. That is not
a token: `Token.parse/1` ignores it, the warning never fires, the
posted comment stores the escapes, and nobody is pinged. It bites a
host with `notify` off — `config :phoenix_kit_comments, :leaf_notify,
false`, or a Leaf older than 0.11 — that uses `Embed` or
`forward_leaf_event/2`. A current Leaf (0.13, `notify` on) delivers
`{:leaf_changed, _}` to the component and never takes this clause.

A writer who escaped the trigger (`\@[…]`) must stay literal. The
helper already does that; the forward path has to call it.

**Fixed:** the `:draft` / `:reply` `leaf_content_changed` clause
unescapes before `put_draft/2`. Edit was already correct.
`test/integration/leaf_mentions_test.exs` posts a forwarded reply,
asserts the stored token, the mention row, the warning, and that an
escaped trigger is not asked.

## Checked, not re-filed

The findings in `CLAUDE_REVIEW.md` (suggestions without `notify`
crashing the host, search with a nil `pk_scope`, warnings stuck to the
wrong draft, duplicate suggestion functions) are still fixed. This pass
did not reopen them.
