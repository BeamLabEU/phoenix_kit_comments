# PR #17 Follow-up — PhoenixKitComments.Embed macro

After-action for `CLAUDE_REVIEW.md` (post-hoc review of the merged `PhoenixKitComments.Embed` macro). Verdict was **Approve**, no blocking issues. (Review lives at repo root; this file sits alongside it per the workspace convention of not editing reviewer artifacts.)

## Fixed (post-review, maintainer commits)
- ~~**Note 1** — the soft-dep moduledoc example mapped `forward_leaf_event/2`'s `:pass` return via a wildcard, so it would consume *every* `{:leaf_changed, …}` including a host's own non-comments Leaf editor.~~ Fixed in `1d92352`: the example now matches `:pass` explicitly and documents that the bare `{:noreply, socket}` only fits a host whose sole Leaf editor is the comments composer. (The hard-dep hook in the same file always got this right.)
- ~~**credo `--strict`** — `Design.AliasUsage` flagged the fully-qualified `CommentsComponent` reference in `__forward_leaf__/2`.~~ Aliased in `9af5e67`. `mix precommit` green afterward.

## Skipped (with rationale)
- **Note 3** — `__forward_leaf__/2` is `@doc false` but technically public. No action; double-underscore naming makes accidental external use unlikely and it's intentional as a lifecycle-hook body. (Review concurred it's acceptable.)

## Fixed (Batch 1 — 2026-06-08)
- ~~**Optional hook test** (review's "Suggested follow-ups" + Note 2) — lock the `Embed` routing contract.~~ Added `test/embed_test.exs` (5 tests): `on_mount/4` attaches the `:phoenix_kit_comments_leaf` `:handle_info` hook; `__forward_leaf__/2` **halts** a `pk-comments:` composer's `{:leaf_changed, …}`, **continues** a host's own non-comments Leaf editor, continues a payload missing an editor id, and continues unrelated messages. Unit-level (bare socket; no DB / running LiveView needed).

## Files touched
| File | Change |
|------|--------|
| `test/embed_test.exs` | New — 5 tests pinning the `Embed` hook + `__forward_leaf__/2` routing contract |
| (doc/credo fixes) | Landed earlier in maintainer commits `1d92352` / `9af5e67`. |

## Verification
- New `test/embed_test.exs`: **5 tests, 0 failures**.
- `mix precommit` was reported green by the maintainer after `9af5e67`.
- **Pre-existing baseline failures (NOT introduced here, unrelated to the Embed work):** `phoenix_kit_comments_test.exs` has 2 reds — `version/0` returns `"0.2.5"` vs `mix.exs` `@version "0.2.6"` (a release-sync miss — `@version` was bumped for the 0.2.6 release but `def version/0` wasn't), and `get_config/0` is not exported. Both are maintainer/release concerns; left untouched (releases are boss-only).

## Open
None.
