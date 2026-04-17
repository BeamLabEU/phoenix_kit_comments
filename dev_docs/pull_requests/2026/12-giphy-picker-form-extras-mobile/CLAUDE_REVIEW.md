# PR #12 — Add Giphy picker, :form_extras slot, and responsive mobile overhaul

**Author:** alexdont | **Date:** 2026-04-16 | **Reviewer:** Claude

## Summary

Adds optional Giphy GIF picker to the comment form (admin-gated), a `:form_extras` slot for
parent-project metadata injection, character counter + Cancel button, and a responsive mobile
overhaul of the entire comments component. Breaking: `Comment.changeset/2` no longer requires
`:content`; either content or a GIF is accepted.

## Files Changed (9)

| File | Change |
|------|--------|
| `lib/phoenix_kit_comments.ex` | Giphy API functions: `giphy_enabled?/0`, `search_giphy/2`, `get_giphy_api_key/0`, `get_giphy_rating/0` |
| `lib/phoenix_kit_comments/schemas/comment.ex` | Changed validation — `:content` no longer required; `validate_content_or_giphy/1` added |
| `lib/phoenix_kit_comments/web/comments_component.ex` | New events (giphy_search, select_giphy, remove_giphy, cancel, toggle), updated add_comment, :form_extras slot, first_error_message helper |
| `lib/phoenix_kit_comments/web/comments_component.html.heex` | Giphy picker UI, responsive overhaul |
| `lib/phoenix_kit_comments/web/settings.ex` | Giphy settings defaults + assigns |
| `lib/phoenix_kit_comments/web/settings.html.heex` | Giphy Integration settings card |
| `mix.exs` | Add `{:giphy_api, "~> 0.1"}` dependency; bump to 0.1.5 |
| `mix.lock` | Updated |
| `CHANGELOG.md` | 0.1.5 entry with feature + breaking change |

## Phase 1 Findings

### ✅ Positives

- **Feature-gated correctly**: Giphy only activates when both `comments_giphy_enabled == true` AND API key is non-empty. Disabled by default.
- **Admin-configurable**: enable toggle, API key (password input), content rating (G/PG/PG-13/R) all in `/admin/settings/comments`.
- **`:form_extras` slot**: Clean design — any `name="metadata[<key>]"` inputs merge into `comment.metadata` on submit. Reserved key `"giphy"` is documented.
- **Breaking change documented**: CHANGELOG is explicit about the changeset validation change and what downstream consumers need to check.
- **No migration needed**: `metadata` was already JSONB; GIF data slots in without schema change.
- **Mobile responsive**: `flex-col`/`sm:flex-row` breakpoints, `min-w-0 truncate` on user email, hidden bullet on mobile — solid responsive work.
- **`first_error_message/1`**: Private helper defined in the component — surfacing the specific error on failed submit is good UX.
- **`validate_content_or_giphy/1`**: Logic is clean and handles nil content properly via `ensure_content_not_nil/1`.

### ⚠️ Concerns

**1. `Application.put_env` at runtime (medium)**

```elixir
# In search_giphy/2:
Application.put_env(:giphy_api, :api_key, get_giphy_api_key())
```

`Application.put_env/3` is a global side effect. In a concurrent system this is not thread-safe —
if two requests call `search_giphy/2` simultaneously with different keys (e.g., multi-tenant future),
one request's key could overwrite the other before `GiphyApi.search/2` reads it.

For a single-tenant setup this is fine in practice, but it's a code smell. If `GiphyApi.search/2`
accepts a `:api_key` option, it should be passed there instead. If not, worth noting to the library
author or wrapping with a mutex. Low urgency for now.

**2. No test files included (minor)**

The changeset validation change (removing required `:content`) is a breaking change — it should have
test coverage for:
- content-only comment (still valid)
- GIF-only comment (new valid path)
- empty comment + no GIF (should fail with "can't be blank without a GIF")
- GIF + content (valid)

The PR has 0 test files. Acceptable if tests exist elsewhere, but worth flagging.

## Verdict

**✅ Looks good to merge.** Feature is well-designed, backward-compat is handled (defaults off,
breaking change documented), mobile overhaul is clean. The `Application.put_env` concern is minor
for current single-tenant use. Missing tests are worth a follow-up but not a blocker.

**Recommendation:** Approve and merge. Optional follow-up: add changeset tests and refactor
`search_giphy/2` to pass API key directly when/if `giphy_api` library supports it.

## Phase 2 Findings (post-merge, pre-0.1.5 release)

Re-scan after Sasha's follow-up commit (`6e6675f` — per-call `:api_key`) and before cutting the
`0.1.5` hex release. Precommit is clean (format, credo 0 issues across 200 mods/funs, dialyzer 0
errors). These are for a follow-up `0.1.6`, not release blockers.

### 🔧 Follow-ups for 0.1.6

**1. `validate_content_or_giphy/1` — reserved-key contract is not enforced (should-fix)**

`lib/phoenix_kit_comments/schemas/comment.ex:119-128`

```elixir
has_gif? = is_map(metadata) and Map.has_key?(metadata, "giphy")
```

The changeset treats any `"giphy"` key as "has GIF" regardless of value shape. The `:form_extras`
slot docs say `"giphy"` is reserved, but nothing enforces the contract. If a parent project
accidentally wires a `<input name="metadata[giphy]" value="junk"/>` inside `:form_extras`, the
comment saves with `content=""` and an invalid giphy value; `comment_gif/1`
(`comments_component.ex` around line 513) pattern-matches `%{"url" => url}` so the GIF silently
fails to render — a blank comment on the page.

Fix: tighten the check to require the shape we actually render.

```elixir
has_gif? =
  is_map(metadata) and
    match?(%{"url" => url} when is_binary(url) and url != "", metadata["giphy"])
```

Not a security issue (HEEx escapes, Giphy origin is trusted), but a data-integrity bug on a
documented-reserved key. One line, no breaking change.

**2. Accessibility regressions in Giphy picker (should-fix)**

`lib/phoenix_kit_comments/web/comments_component.html.heex` — picker around lines 106–162.

The mobile overhaul is visually solid but the picker modal dropped some a11y affordances:

- Picker container has no `role="dialog"` / `aria-modal="true"` — assistive tech can't tell it's
  a popup.
- Search input has no `<label>` or `aria-label`; screen readers announce only the placeholder.
- Each GIF `<button>` renders an `<img alt="">` and nothing else — buttons are indistinguishable
  in a screen reader. Use `aria-label={"Select GIF: " <> gif["title"]}` (or the search query as
  fallback) on each button, since `title` isn't in the normalized shape today — may need to
  preserve it through `normalize_giphy_gif/1`.
- Backdrop is click-dismiss only; no `Escape` key handler to close the picker.

**3. Missing `@spec` on public Giphy functions (optional)**

`lib/phoenix_kit_comments.ex:128-186` — `giphy_enabled?/0`, `search_giphy/2`, `get_giphy_api_key/0`,
`get_giphy_rating/0`. Dialyzer infers these cleanly, but explicit specs document the contract
(especially `search_giphy/2`'s `{:ok, [map]} | {:error, :missing_api_key | :giphy_error | term()}`
return shape, which isn't obvious from the implementation).

### Release decision

Shipping `0.1.5` as-is (current mix.exs + CHANGELOG). Findings above are filed here for Sasha to
address in a follow-up `0.1.6` along with the changeset tests flagged in Phase 1.
