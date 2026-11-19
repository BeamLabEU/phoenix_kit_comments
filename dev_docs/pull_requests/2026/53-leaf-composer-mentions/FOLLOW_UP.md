# Follow-up — PR #53

Merged into `main` after #52, which implements the same feature through Leaf's
`notify`. The review of both is `../52-leaf-editor-mentions/CLAUDE_REVIEW.md`.

What became of #53's parts:

- **`mention_people`, `mention_warning`** — kept, documented in the
  component's attr list. The search behind them now runs under the viewer's
  event scope (was `pk_scope`, nil for most hosts); warnings are tied to the
  draft they describe and re-asked only when the mentioned people change.
- **`forward_leaf_event/2` / `Embed` for `:leaf_suggest`** — kept, routed to
  #52's `update(%{leaf: _})` so there is one answer path.
- **`suggestions` on every Leaf** — not kept: without `notify` the question
  goes to the host LiveView and can crash it. Suggestions need `notify`
  (Leaf 0.11+).
- **`leaf_mention_suggestions/0`, `mention_suggestions/3`** — kept as the
  names; bodies merged with #52's.
- **Catalogs** — #52's `pgettext("mentions", …)` entries kept; #53's
  context-less "People"/"Records" are no longer used.

The author-side findings in `CLAUDE_REVIEW.md` here (host-chosen people,
warning text, cross-composer ids) stand as written.
