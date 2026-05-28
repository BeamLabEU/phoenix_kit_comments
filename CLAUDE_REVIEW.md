# PR #14 Review — Stamp `data-comment-uuid` + `data-annotation-uuid` on rendered comments

- **Author:** Sasha Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/14
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-05-12 (review is post-hoc)
- **Diff size:** +7 / −3, 1 file

## Summary

Adds two DOM data attributes to the outermost wrapper of `render_comment/1` in
`lib/phoenix_kit_comments/web/comments_component.ex:525`:

- `data-comment-uuid={@comment.uuid}` — always present.
- `data-annotation-uuid={get_in(@comment.metadata || %{}, ["annotation_uuid"])}` —
  read from JSONB metadata; omitted when nil.

Goal (per PR body): let sibling components on the host page (PhoenixKit's
Etcher annotation overlay) correlate DOM nodes with comment + linked-resource
UUIDs so they can highlight + scroll-to the comment(s) tied to a pinned image
annotation, without reaching into render internals.

## Verdict

**Approve.** Small, focused, behaviorally safe. A couple of minor observations
below, none blocking.

## What's good

- **Minimal surface area.** One render site, two new attributes, no schema or
  API changes. Nothing else in the codebase grepped for the new attribute names,
  so there's no parallel write-up to keep in sync.
- **HEEx handles the nil-omission contract correctly.** Phoenix.HTML drops
  attributes whose value is `nil`, so non-annotation comments render with no
  `data-annotation-uuid` at all — matches the PR description.
- **Attribute escaping is safe.** HEEx escapes attribute values, so even if
  `metadata["annotation_uuid"]` contains odd characters, there's no injection
  risk on the rendered page.
- **Key choice matches the rest of the file.** `metadata` is stored as JSONB
  with string keys (`"giphy"`, `"box_color"`, etc. per the moduledoc at
  `comments_component.ex:31` and usages around lines 122–136), so
  `["annotation_uuid"]` is consistent — not atom-vs-string-key drift.

## Minor observations (non-blocking)

1. **The `|| %{}` guard is redundant.** `Comment.metadata` is declared
   `field(:metadata, :map, default: %{})` at
   `lib/phoenix_kit_comments/schemas/comment.ex:69`, so a freshly loaded
   comment will never have `nil` metadata. Harmless belt-and-suspenders, but
   if you want to match the rest of the file's style,
   `get_in(@comment.metadata, ["annotation_uuid"])` would also work.
   I'd leave it — defensive code at a render site is cheap.

2. **Upstream-concept leakage.** The schema describes `metadata` as
   "Arbitrary JSONB data" — generic by design. Hard-coding the
   `"annotation_uuid"` key here bakes a specific Etcher-integration convention
   into the library's render path. For one attribute it's pragmatic, but if a
   second or third such key shows up (`"thread_uuid"`, `"pin_uuid"`, …) it
   would be worth promoting to a small generic mechanism — e.g. an optional
   `:data_attrs` assign that the host LiveView passes through, or a render
   slot — rather than continuing to enumerate keys inside the component. Not
   for this PR; just flagging the slippery-slope direction.

3. **No test coverage for the new attributes.** A render snapshot or a single
   `Floki.attribute/2` assertion in whatever component test already exists
   would lock in the contract for downstream code that depends on the
   attribute being there. Cheap to add later.

4. **Attribute ordering inside the tag is now alphabetical-ish-but-not-quite**
   (`data-comment-uuid`, `data-annotation-uuid`, `class`). Pure nit; HTML
   doesn't care. Mention it only because formatters sometimes do.

## Things I checked and ruled out

- **N+1 / preload regression** — none; the change reads fields already on the
  struct (`uuid`, `metadata`).
- **Public API change** — none.
- **Migration / schema impact** — none.
- **CSP / XSS surface** — none; HEEx attribute escaping covers it, and the
  values originate from server-side JSONB, not user-typed HTML.
- **Other call sites** — grep for `data-comment-uuid`/`data-annotation-uuid`
  shows the component is the sole producer; no consumer code in this repo
  (consumers live in PhoenixKit/Etcher per PR body).

## Suggested follow-ups (optional)

- Add a one-line test asserting both attributes render (or are omitted) under
  the expected conditions.
- If more "linked resource" keys land in `metadata`, refactor to a generic
  `:data_attrs` slot/assign rather than enumerating keys inside
  `render_comment/1`.
