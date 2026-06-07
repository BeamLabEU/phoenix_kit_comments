# PR #17 Review — `PhoenixKitComments.Embed` macro for host Leaf-event forwarding

- **Author:** Max Don (`mdon`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/17
- **Branch:** `mdon:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-06 (review is post-hoc)
- **Diff size:** +90 / −0, 1 new file (`lib/phoenix_kit_comments/embed.ex`)

## Summary

Adds `PhoenixKitComments.Embed`, a `use`-able macro for host LiveViews that
hard-depend on `phoenix_kit_comments`. It wires the host to forward the Leaf
composer's `{:leaf_changed, …}` process message into
`CommentsComponent.forward_leaf_event/2`. Without this hop the rich-text
editor's content never reaches the `LiveComponent` (which has no `handle_info`
of its own), so "Post comment" silently posts an empty body. Implemented as an
`on_mount` + `attach_hook(:handle_info)` lifecycle hook delegating to the
existing public `forward_leaf_event/2`. Purely additive.

## Verdict

**Approve.** Correct, focused, well-documented. No blocking issues. A couple of
minor/optional notes below.

## What's good

- **Right pattern.** Lifecycle hook (`attach_hook(:handle_info)`) instead of
  injected `handle_info` clauses, so it composes with a host that already
  defines its own `handle_info` — no "clauses should be grouped" warning, no
  clobbering. The moduledoc explains the non-obvious process-message hop well.
- **Routing by `editor_id`, not clause order.** `forward_leaf_event/2` only
  handles `"pk-comments:"`-prefixed editors and returns `:pass` otherwise; the
  hook maps `{:noreply, _} → {:halt}` and `:pass`/anything-else → `{:cont}`. A
  host with its own unrelated Leaf editor still receives those events. This is
  more robust than `MediaBrowser.Embed`'s `@before_compile` clause-injection
  approach, which depends on the user's clause being defined first.
- **Hook mechanics are valid.** `:handle_info` is a real `attach_hook` stage;
  `:halt` correctly suppresses the host's own `handle_info` for comments
  editors (the component handles them via `send_update`), and `:cont` passes
  everything else through.
- **`on_mount(:default, …)` matches.** `on_mount(PhoenixKitComments.Embed)`
  expands to `{Module, :default}`; the callback head is `on_mount(:default, …)`.
- **No double-forward when combined with `MediaBrowser.Embed`.** If a host uses
  both, the comments hook runs first and `:halt`s our editors before
  MediaBrowser's injected `{:leaf_changed, _}` fallback can re-forward them.
- **Compiles clean** (`mix compile` green).

## Minor observations (non-blocking)

1. **Soft-dep doc example swallows unrelated `:leaf_changed`.** ✅ **Fixed** (see
   Post-review fixes). The moduledoc's runtime example for soft-dep hosts mapped
   `forward_leaf_event/2`'s `:pass` return to `{:noreply, socket}` via a
   wildcard, i.e. it consumed *every* `{:leaf_changed, …}` — including a host's
   own non-comments editor. The hard-dep hook in this same file gets this right
   (`:pass → {:cont}`). For the cited `phoenix_kit_staff` `PersonShowLive`
   (comments is the only Leaf editor) it was fine, but the example reads as the
   canonical soft-dep recipe, so it now matches `:pass` explicitly and documents
   that the bare `{:noreply, socket}` only fits a host whose only Leaf editor is
   the comments composer.

2. **No test coverage.** Consistent with the repo (only
   `phoenix_kit_comments_test.exs` exists), so not a regression. A small test
   that `on_mount/4` attaches the hook and that `__forward_leaf__/2` returns
   `{:halt}` on a `{:noreply}` and `{:cont}` on `:pass` would lock in the
   routing contract cheaply. Optional.

3. **`__forward_leaf__/2` is `@doc false` but public.** Double-underscore
   naming makes accidental external use unlikely and it's intentional as a
   lifecycle-hook body — acceptable, just noting it's technically callable.

## Things I checked and ruled out

- **Iron-law (no queries in mount)** — N/A; `on_mount` only attaches a hook.
- **Double registration across remounts** — `attach_hook` runs once per mount;
  hook name `:phoenix_kit_comments_leaf` is fixed and fine for single use.
- **Message-swallowing of non-comments info messages** — none; the catch-all
  `__forward_leaf__(_msg, socket) → {:cont, socket}` passes everything through.
- **Public API / schema / migration impact** — none; purely additive.

## Post-review fixes applied

Committed to `main` after this review:

- **Tightened the soft-dep moduledoc example** (note 1) — match `:pass`
  explicitly instead of a wildcard, and document that the bare
  `{:noreply, socket}` only fits a host whose only Leaf editor is the comments
  composer. Doc-only, no behavior change. (`1d92352`)
- **Aliased `CommentsComponent` in `__forward_leaf__/2`** to satisfy
  `credo --strict` (`Design.AliasUsage`), which flagged the fully-qualified
  reference. Safe here because the hook body runs in this module, not injected
  into the caller. (`9af5e67`)
- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `format --check-formatted`, `credo --strict`, `dialyzer`) now passes green.

## Suggested follow-ups (optional)

- Add a one-line test for the hook attach + the `{:halt}`/`{:cont}` routing.
