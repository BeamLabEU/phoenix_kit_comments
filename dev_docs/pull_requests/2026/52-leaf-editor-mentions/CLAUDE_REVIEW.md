# Claude Review — PRs #52 and #53

**Reviewer:** Claude
**PRs:** #52 "Add @ and # mentions to the rich (Leaf) comment editor" (alexdont) ·
#53 "Fix the Leaf comment composer offering no @ or # mentions" (mdon)
**Reviewed:** 2026-11-19 · **Merged:** both into `main`, #52 first

Both PRs built the same feature — the `@`/`#` popup in the Leaf composer —
along different routes, and conflicted throughout `comments_component.ex` and
every catalog. #52 has Leaf talk to the component directly (`notify`, Leaf
0.11+), which needs no host wiring, and also adds chips, the visual-mode
unescape and notification links. #53 routes the editor's request through the
host (`forward_leaf_event/2`, `Embed`) and adds two host attrs the Projects
module depends on (`mention_people`, `mention_warning`). The merge keeps #52's
route as the one answer path and folds #53's attrs and forwarding into it.

## Findings

### BUG - HIGH — #53: a Leaf without `notify` sent the popup's question to the host, which may crash on it
#53 passed `suggestions` whenever mentions were on, and never `notify`. Leaf
then sends `{:leaf_suggest, …}` to the host LiveView (`self()`). A host with a
`handle_info({:leaf_changed, _})` clause and no catch-all — the shape core's own
docs show — crashes on the first `@`; one that does have a catch-all leaves the
popup spinning, because core up to 3.6.1's `CommentsForwarding` routes only
`:leaf_changed`.
**Fixed:** `suggestions` (and `mentions`) are passed only when the installed Leaf
has `notify` (#52's `leaf_notify?/0`), and the component receives the question
itself. #53's `forward_leaf_event/2` clause for `:leaf_suggest` stays (core #1046
and `Embed` forward it) and now hands the message on as `leaf: msg`, so both
routes end in the same `update(%{leaf: _})` clause, with its own-editor check.

### BUG - MEDIUM — #53: the search ran with `assigns[:pk_scope]`, which is nil for most hosts
Hosts that do not pass `pk_scope` (the CRM and Projects embeds) searched with
`scope: nil`, so a handler that scopes on it offered less, or nothing.
**Fixed:** `mention_suggestions/3` uses the event scope (`assigns_event_scope/1`:
the host's scope, otherwise one built for the viewer), as #52 did.

### BUG - MEDIUM — #53: mention warnings outlived their draft and came from the edit form
`mention_warnings` was set on every draft change but never cleared: after
posting, cancelling or opening a reply the old warnings stayed under the empty
box. The edit form's content also fed it, so editing a comment showed that
comment's warnings under the new-comment composer.
**Fixed:** warnings are stored with the text they were worked out for
(`%{for, uuids, list}`) and `mention_warnings/1` shows them only while that text
is still the draft. Only drafts compute them (`put_draft/2`, used by the
textarea, the forwarded Leaf content and the `notify` route).

### IMPROVEMENT - MEDIUM — #53: the host's check ran on every keystroke
`mention_warning` was called for every mentioned person on each draft update
(150 ms textarea / 400 ms Leaf debounce); a host check that reads the database
paid that per keystroke. **Fixed:** the host is asked again only when the set of
mentioned people changes.

### IMPROVEMENT - MEDIUM — #53: `:mention_warnings` in `@thread_ctx_keys`
The thread context exists so typing does not re-render the comment list; a key
that changes with the draft re-rendered every comment. The composers read the
full assigns, so the key was never needed there. **Removed.**

### IMPROVEMENT - MEDIUM — two implementations of one feature
Two trigger configs (`mention_suggestions/0`, `leaf_mention_suggestions/0`), two
result builders, and `gettext("Records")` next to `pgettext("mentions",
"Records")`. **Unified:** `leaf_mention_suggestions/0` (#52's triggers — token
classes, `#` needs a letter, `max_length` — plus #53's `max_results`) and one
`mention_suggestions/3` (#52's rows with icons and the cleaned-title retry,
#53's host people first, de-duplicated by `{type, uuid}`). The catalogs keep the
`mentions` context, which also keeps "Records" apart from the recorder's
"Record"; `main`'s "Record" translations were checked correct in all 7 locales.

### NITPICK — stale comment
"The @/# typeahead, on the PLAIN textarea only" no longer held. Reworded.

### Checked, no change
- #52 `unescape_mention_tokens/1` only rewrites complete tokens and leaves an
  escaped trigger alone; `comment_link/1` returns `nil` without a page and
  casts the annotation uuid (the rule moved from `Index`, unchanged).
- `PhoenixKitCommentsJumpToComment` validates the hash against a uuid pattern
  before `querySelector`, looks only inside its own thread, and jumps once.
- `notify` is detected from Leaf's attr declarations; the lock resolves Leaf
  0.12.0, so chips and `notify` are both live.

## Tests
- `leaf_mentions_test.exs`: host people first through the `notify` route; a
  warning follows the draft, is asked once per set of people and clears on
  post; a raising check is no warning.
- `embed_test.exs`: the forwarded `:leaf_suggest` arrives as `leaf: msg`.
- Full suite: 458 tests, 0 failures. `mix precommit` clean.
