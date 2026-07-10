# PR #28 Review — Modernize the settings page; delegate resource resolution to core

- **Author:** Alexander Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/28
- **Branch:** `alexdont:feat/settings-page-modernization` → `BeamLabEU:main`
- **State:** Merged 2026-07-11 (review is post-hoc)
- **Diff size:** +1716 / −437, 8 files (main module, settings LiveView + template,
  `mix.lock`, and 4 gettext catalogs: `.pot` + `en`/`et`/`ru` `.po`)

## Summary

Three independent changes under one PR:

1. **Delegate resource resolution to core.** `PhoenixKitComments` drops its own
   ~170-line resource-resolution engine (handler registry + path-template
   expansion) and `defdelegate`s to the new `PhoenixKit.ResourceLinks`:
   - `get_resource_path_templates/0` → `ResourceLinks.get_resource_path_templates/0`
   - `update_resource_path_templates/1` → `ResourceLinks.update_resource_path_templates/1`
   - `resolve_resource_context/1` → `ResourceLinks.resolve/1` (via `as:`)
   - `notify_resource_handler/4` now reads `ResourceLinks.handlers()` instead of a
     private, comments-local `resource_handlers/0`.
2. **Settings-page modernization (`settings.html.heex`).** Five separate cards
   collapse into a single card with lightweight in-card section headers
   (new `settings_section_header/1` component in `settings.ex`); toggles/inputs
   restyled to daisyUI label patterns; Reset button gains a `data-confirm`.
3. **Gettext coverage.** Every user-facing string on the settings page (template
   + `settings.ex` flashes) is wrapped in `gettext`/`ngettext`, the module's own
   backend is rebound (`use Gettext, backend: PhoenixKitComments.Gettext`), and
   the `.pot` + `en`/`et`/`ru` `.po` catalogs are extended and **fully translated**.

## Verdict

**Approve — no code changes applied.** This is a clean PR. The load-bearing part
(the delegation) was traced end-to-end against the installed core and is
**behaviour-preserving**; the template rework introduces no nested-form or
missing-assign regressions; the gettext rebind follows the exact convention
already proven in `web/index.ex` and `web/comments_component.ex` (PR #27). No
correctness defects were found. The findings below are quality/observation level;
each is left unfixed **on purpose** with the rationale recorded, because the
"fixes" would either discard curated translations or inject English-fallback
strings into an otherwise fully-translated catalog — net-negative at review time.

## Why the delegation is safe (verified, not assumed)

The removed private engine and `PhoenixKit.ResourceLinks` were diffed clause by
clause. Core is a **strict superset** of the deleted comments logic:

- **Same return contract.** `ResourceLinks.resolve/1` groups by `resource_type`,
  keys the result by `{resource_type, resource_uuid}`, and each value carries
  `:title`, `:full_title`, `:path`, `:prefixed` — identical to the old
  `resolve_resource_context/1`. Confirmed against the only consumer,
  `web/index.ex:273`, which reads `info[:prefixed]`, `info[:full_title]`,
  `info.title`, and `info.path` — every key still present.
- **Same default handlers, plus additive tiers.** Core's
  `default_resource_handlers/0` registers `"post" => PhoenixKitPosts`,
  `"file" => PhoenixKit.Annotations`, `"user" => PhoenixKit.Users.CommentResources`
  — the same trio the comments module registered — and *adds*
  `"integration"` + module-declared `resource_links/0` handlers. Nothing the
  comments admin resolved before stops resolving; some types now resolve that
  previously fell through to path templates. No regression, a capability gain.
- **Template fallback preserved.** With no handler match, core still falls back to
  the `comment_resource_paths` setting via the same `:uuid` / `:prefix` /
  `:metadata.KEY` substitution and the same 15-char truncation — byte-for-byte the
  old `resolve_via_path_template/2`.
- **`notify_resource_handler/4`** now dispatches through `ResourceLinks.handlers()`,
  a superset of the old private map, so reaction/create/delete callbacks reach at
  least the same handlers as before.

The installed dep is **phoenix_kit 1.7.181**, which exports all four delegated
functions (`resolve/1`, `handlers/0`, `get_resource_path_templates/0`,
`update_resource_path_templates/1`) — verified in
`deps/phoenix_kit/lib/phoenix_kit/resource_links.ex`.

## Findings

### IMPROVEMENT - MEDIUM — gettext sentence fragmentation in the "Resource Link Patterns" blurb  *(not fixed — see rationale)*

`settings.html.heex` splits two running sentences into short `gettext/1`
fragments interleaved with `<code>` tokens:

```heex
{gettext("Use")} <code>:uuid</code>
{gettext("for resource ID,")}
<code>:metadata.KEY</code>
{gettext("for values from comment metadata, and")}
<code>:prefix</code>
{gettext("to include the site URL prefix.")}
...
{gettext("Example:")} <code>/products/:uuid</code> {gettext("or")} ...
```

Fragments like `"Use"`, `"for resource ID,"`, `"or"`, `"Example:"` are the classic
i18n anti-pattern: word order around the `<code>` placeholders is frozen to
English, and a translator sees grammarless snippets. It renders correctly in
every language (the fragments *are* translated), so this is a translation-quality
issue, not a defect.

**Why not fixed:** the clean form (one msgid per sentence with interpolated
placeholders, e.g. `gettext("Use %{uuid} for the resource ID, …", uuid: "…")`)
would change the freshly-added msgids and therefore **discard the curated `ru`
and `et` translations** the same PR just added for these fragments. That is
net-negative to do at review time. Recommended for a future dedicated i18n pass
that re-extracts and re-translates in one motion.

### NITPICK — `validate_resource_path/2` error flashes are not translated  *(not fixed — see rationale)*

`settings.ex:307–321` still returns bare English strings shown via
`put_flash(:error, …)`:

- `"Resource type is required"`, `"Path template is required"`
- `"Path template must start with / or :prefix"`
- `"Path template must be a relative path"`
- `"Path template must contain :uuid or :metadata.KEY placeholders"`

On the very page this PR "gettext-covered," these admin-facing validation errors
remain un-wrapped — a small coverage gap. **Why not fixed:** wrapping them adds
new msgids that would land **untranslated** in the `ru`/`et` catalogs (which are
otherwise 100% translated — the only empty `msgstr` is the PO header), injecting
English fallbacks into a curated catalog. The correct home for this is the
translation workflow (`gettext.extract` → `gettext.merge` → translate `ru`+`et`),
not a review-time patch. Logged here so it isn't lost.

### OBSERVATION — new hard dependency on `PhoenixKit.ResourceLinks` vs. the `~> 1.7` floor

The delegation makes `PhoenixKit.ResourceLinks` a **runtime requirement**: a host
that resolves an older `1.7.x` without that module would hit
`UndefinedFunctionError` the moment the moderation dashboard or settings page
loads. `mix.exs` still pins `pk_dep(:phoenix_kit, "~> 1.7")`, which permits such
versions. In practice this repo co-releases with core and bumps the lock every
release (the installed 1.7.181 has the module), so the risk is low — but at the
next release the constraint could be tightened to the `1.7.x` that introduced
`ResourceLinks` to make the requirement explicit. Left to the maintainer, who
owns the lock/co-release cadence.

### OBSERVATION — `comments_rich_text` missing from the AGENTS.md settings table

The PR moves the pre-existing `comments_rich_text` toggle into the new "General"
section. The setting is loaded/saved/reset correctly in `settings.ex`
(`@allowed_settings`, `assign_settings_defaults/1`, `load_settings/1`, and the
`reset_defaults` map all include it), but the **Settings Keys** table in
`AGENTS.md` never listed it. Pre-existing doc gap, surfaced (not caused) by this
PR; worth a one-row addition next time `AGENTS.md` is touched.

## What Was Done Well

- **Delegation with a shim, not a hard cutover.** `settings_section_header/1` is a
  deliberate local copy of core's `FormSection.section_header/1` under a distinct
  name, with a `@doc` explaining it renders identically today and won't collide
  with the core import once core exports it. That's the right call for a package
  that ships ahead of a core release.
- **Net −437 lines by deleting duplicated logic** and routing both the comments
  admin and the Activity feed through one resolver — the duplication that used to
  drift between the two is gone.
- **`data-confirm` on Reset** — the reset wipes moderation/limits/Giphy/attachment
  settings; the added confirmation is a real UX safeguard.
- **Complete, not partial, i18n.** Every new string is translated in both `ru` and
  `et` (verified: only the PO header `msgstr` is empty), matching the bar set by
  PR #27 rather than leaving English stubs behind.
- **Convention-faithful rebind.** `use Gettext, backend: PhoenixKitComments.Gettext`
  after `use PhoenixKitWeb, :live_view` is the same last-write-wins backend
  override already proven in two sibling LiveViews; compiles clean under
  `--warnings-as-errors`.
