# PR #26 Review — Link user-resource comments + friendlier fallback chip

- **Author:** Alexander Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/26
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-24 (review is post-hoc)
- **Diff size:** +28 / −4, 2 files (`lib/phoenix_kit_comments.ex`, `lib/phoenix_kit_comments/web/index.ex`)

## Summary

Two small, additive moderation-dashboard improvements:

1. **`"user"` resource handler.** `default_resource_handlers/0` now registers
   `PhoenixKit.Users.CommentResources` as the `"user"` handler when that module
   is loaded — gated on `Code.ensure_loaded?/1`, exactly like the existing
   `"post"` (`PhoenixKitPosts`) and `"file"` (`PhoenixKit.Annotations`) entries.
   The effect: a comment with `resource_type: "user"` resolves to the user's
   display name + admin detail page (`/admin/users/view/:uuid`) with their avatar
   as the chip thumbnail, instead of rendering a bare uuid.

2. **Friendlier no-handler fallback chip.** When a `resource_type` has neither a
   registered handler nor a host-configured path template, the chip in
   `resource_chip/1` now renders a `hero-tag` icon + a humanized type label +
   a 6-char uuid (was: a ghost badge with the raw type key + an 8-char uuid).
   The `title` tooltip now reads `"<type>: <uuid>"` (was: bare uuid). A new
   private `humanize_resource_type/1` does `"test_page" -> "Test page"`.

## Verdict

**Approve as merged.** Correct, well-scoped, and faithful to the established
resource-handler conventions. No bugs found. All notes below are observations /
nits; no code changes were required.

## What was done well

- **Handler registration mirrors the established pattern exactly.** Same
  `Code.ensure_loaded?/1` gate, same `Map.put` shape, same "core context owns the
  resolution" delegation as `"post"`/`"file"`. Nothing bespoke.
- **Raw-path design is correct.** `PhoenixKit.Users.CommentResources` returns the
  *unprefixed* path `/admin/users/view/:uuid` and lets the renderer apply
  `Routes.path/1` exactly once (via the `prefixed: true` branch in
  `resolve_for_type/2` → `resource_url/2`). Pre-prefixing in the handler would
  double-prefix under a `url_prefix`; the handler's own comment calls this out.
- **The hardcoded route is real and consistent.** `/admin/users/view/:id` exists
  in phoenix_kit core (`integration.ex:433`), and core's own
  `table_row_menu.ex` links to it with the identical
  `Routes.path("/admin/users/view/#{uuid}")` form.
- **Graceful degradation end-to-end.** If the user row is missing or the handler
  raises, `resolve_comment_resources/1` returns `%{}` → `resolve_for_type/2`
  falls through to the path template → if none, the fallback chip renders
  (humanized `"User"` + short uuid). No crash, no bare-uuid regression.
- **No list drift.** The dashboard's `resource_type` filter is populated from
  `PhoenixKitComments.list_resource_types/0` (a DB `distinct` query), not a
  hardcoded enum, so `"user"` appears in the filter automatically — nothing else
  had to be kept in sync.
- **Fallback chip is a genuine UX win.** Icon + humanized label + tighter uuid,
  and the richer `title` tooltip (`type: uuid`) restores the full-type context
  the old bare-uuid tooltip dropped.
- **Release artifacts left to the maintainer.** The PR's second commit
  (`8753f67`) deliberately reverts the contributor's version/CHANGELOG bump —
  matches the repo convention that the maintainer owns versioning.
- **Gate is green.** `mix compile --force --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo --strict` (no issues), and `mix test`
  (42 tests, 0 failures) all pass on the merged tree.

## Findings

1. **(Observation) The built-in `"user"` handler now wins over a host's `"user"`
   path template.** `resolve_for_type/2` tries the handler first and only falls
   through to `resolve_via_path_template/2` when the handler returns an empty
   map. Because `PhoenixKit.Users.CommentResources` ships in phoenix_kit core,
   any host that had previously mapped `"user"` to its *own* page via a
   `comment_resource_paths` template will now silently switch to core's
   `/admin/users/view/:uuid`. This is consistent with the pre-existing
   `"post"`/`"file"` precedence and is almost certainly the intended better
   default — but it's a real, undocumented behavior change for such a host, and
   there is no per-type opt-out. **Not a bug.** Worth a one-line CHANGELOG/docs
   note so the precedence is on record.

2. **(Nit) `String.capitalize/1` flattens casing in the fallback label.**
   `humanize_resource_type/1` lowercases everything after the first character, so
   multi-word / acronym types render imperfectly: `"api_key" -> "Api key"`,
   `"GitHubRepo" -> "Githubrepo"`. This only affects the *unconfigured-type*
   fallback chip (configured types resolve via a handler/template and never reach
   it), and resource types are conventionally lowercase snake_case
   (`"post"`, `"file"`, `"user"`), so the impact is cosmetic and small. A
   per-word capitalize would read marginally better but is over-engineering for a
   fallback label — **left as-is.**

3. **(Observation) Same datum, two renderings.** The *resolved* chip
   (`resource_chip_body/1`) still shows the raw type key in a ghost badge
   (`{@comment.resource_type}`), while the *fallback* chip now humanizes it.
   These are different visual treatments in different contexts (thumbnail-or-badge
   vs. icon-plus-label), so it isn't jarring in practice, but the two paths format
   the same field differently. **Not changed.**

## On tests

No test was added. `humanize_resource_type/1` is a private helper inside a
private function-component (`resource_chip/1`), so pinning it would mean either
exposing internals or standing up a LiveView render harness for a private
component — over-engineering for a fallback display label. Consistent with the
existing suite, which is unit-level (behaviour/callback/changeset introspection,
no DB sandbox) and does not exercise the chip renderers. Recording the
deliberate skip here so the gap is on record.

## Conclusion

Additive, correct, and conventional. The `"user"` handler is a faithful clone of
the `"post"`/`"file"` pattern pointing at a real core route, and the fallback
chip is a clean UX improvement with graceful degradation. The only thing worth
surfacing is the handler-over-template precedence for `"user"` (finding #1),
which is intended behavior but deserves a changelog line. Approve as merged.
