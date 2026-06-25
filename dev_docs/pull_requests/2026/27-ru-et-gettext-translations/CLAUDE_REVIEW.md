# PR #27 Review — Add Russian and Estonian translations for the comments UI

- **Author:** Alexander Don (`alexdont`)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_comments/pull/27
- **Branch:** `alexdont:main` → `BeamLabEU:main`
- **State:** Merged 2026-06-26 (review is post-hoc)
- **Diff size:** +2660 / −2, 8 files (1 new backend module, 2 rebound LiveViews,
  `mix.exs`, and 4 gettext catalogs: `.pot` + `en`/`et`/`ru` `.po`)

## Summary

Gives the comments module its **own gettext backend** so its UI strings can be
translated independently of phoenix_kit core, then ships Russian + Estonian
catalogs.

1. **`PhoenixKitComments.Gettext`** — new `use Gettext.Backend, otp_app:
   :phoenix_kit_comments` backend, catalogs under `priv/gettext`.
2. **Rebind** — `web/index.ex` and `web/comments_component.ex` add
   `use Gettext, backend: PhoenixKitComments.Gettext` *after* `use PhoenixKitWeb`,
   so their `gettext/ngettext` calls (and those in the colocated
   `index.html.heex` / `comments_component.html.heex`) resolve against this
   package's catalogs.
3. **`mix.exs`** — adds a `pk_dep/3` helper (`PHOENIX_KIT_PATH` env → local path
   dep, unset → the published `~> 1.7` pin) and adds `priv` to the package
   `files` so the catalogs ship.
4. **Catalogs** — 117 source strings extracted, fully translated to `ru`
   (3 plural forms) and `et` (2 plural forms); `en` is the empty reference.

## Verdict

**Approve with one fix applied.** The mechanism is correct, the translations are
clean (no fuzzy flags, no untranslated strings, placeholder- and plural-safe),
and the locale wiring matches an established phoenix_kit convention. One real
issue: the new Russian catalog's `nplurals=3` plural form makes **`mix dialyzer`
fail** (an `Expo.PluralForms` opaqueness warning in the generated backend),
which breaks the repo's `precommit` / `quality.ci` gate and would block a
release. Fixed here with a targeted ignore filter. A doc improvement was also
applied; the rest are observations.

## Why the rebind actually works (verified, not assumed)

This is the load-bearing claim of the PR, so it was traced end to end against the
installed deps (Gettext **1.0.2**, phoenix_kit on the `~> 1.7` tree):

- **Backend resolution is a module attribute, last-write-wins.** In Gettext 1.0
  `use Gettext, backend: X` does `Module.put_attribute(:__gettext_backend__, X)`
  + `import Gettext.Macros`, and the macros read that attribute at expansion time
  (`deps/gettext/lib/gettext/macros.ex` `backend/1`). Core's `PhoenixKitWeb`
  already does `use Gettext, backend: PhoenixKitWeb.Gettext` inside its
  `:live_view` / `:live_component` macros, so the second `use` in these modules
  simply overwrites the attribute. The override is **module-wide** (every call
  site, including the `.heex` templates compiled into the module), and silent — a
  `--warnings-as-errors` compile is clean.
- **Templates are covered.** `index.html.heex` / `comments_component.html.heex`
  compile into their (now-rebound) modules, so their gettext calls resolve to the
  comments backend too — confirmed by the `.pot` carrying refs from both the
  `.ex` and `.html.heex` files.
- **Locale needs no per-backend wiring.** Core sets *both* the backend-specific
  locale **and** the process-global locale (`Gettext.put_locale/1`) in its admin
  on-mount hook (`phoenix_kit_web/users/auth.ex`), explicitly so "feature modules
  with their own backends … also pick up the new locale." `PhoenixKitComments.Gettext`
  has no per-backend locale, so it reads that global value. This is the same
  pattern core cites for `PhoenixKitProjects.Gettext`.
- **The `ru`/`et` catalog names line up with the resolved locale.** Core stores
  the *resolved dialect* in the global locale (`DialectMapper`). `ru` and `et`
  map to themselves, so `priv/gettext/ru` and `priv/gettext/et` match. `en`
  resolves to `en-US` (no catalog) but its msgstrs are empty anyway, so English
  renders the source either way. Any other locale falls back to the English
  source — graceful, no crash.

## What was done well

- **Self-contained i18n, no core coupling.** A dedicated backend + own
  `priv/gettext` means the module owns its extract/merge lifecycle and can't be
  broken by core catalog changes. Matches the existing `PhoenixKitProjects`
  precedent.
- **Catalog hygiene is excellent.** 0 fuzzy flags, 0 untranslated strings in
  `ru`/`et`, correct `Plural-Forms` headers (`ru` nplurals=3 with the standard
  formula, `et` nplurals=2), and every plural form populated.
- **Placeholder integrity is intact.** Programmatic check of all 117 entries:
  no `%{…}` placeholder added, dropped, or renamed in any `ru`/`et` string. This
  matters — an *extra* placeholder in a translation is a runtime binding error,
  not a cosmetic glitch. None found.
- **Translations read idiomatically** (spot-checked: Отмена/Сохранить/Удалить/
  Ответить/Нравится/Не нравится, etc.).
- **`pk_dep/3` is publish-safe.** With `PHOENIX_KIT_PATH` unset it returns the
  plain `{:phoenix_kit, "~> 1.7"}` tuple, so `mix hex.publish` / CI see the
  published pin; the path+`override: true` branch only engages for local
  cross-repo dev.
- **`priv` correctly added to package `files`** — without it the catalogs would
  not ship and translations would silently vanish for consumers.
- **Gate is green** *after the dialyzer fix below*: full `mix precommit` passes
  end to end — `compile --force --warnings-as-errors`, `deps.unlock
  --check-unused`, `hex.audit` (no retired packages), `format --check-formatted`,
  `credo --strict` (no issues), `dialyzer` (passed), plus `mix test` (42 tests,
  0 failures).

## Findings

1. **(BUG — MEDIUM, fixed) The Russian catalog breaks `mix dialyzer`.** On the
   merged tree, `mix dialyzer` exits non-zero with a `call_without_opaque`
   warning at `lib/phoenix_kit_comments/gettext.ex:1`:

   ```
   Gettext.Plural.plural({<<_::16>>, %Expo.PluralForms{nplurals: 3, plural: …}}, _)
   ```

   `use Gettext.Backend` compiles the PO `Plural-Forms` header into a literal
   `%Expo.PluralForms{}` (an `@opaque` struct) and passes it to
   `Gettext.Plural.plural/2` from the generated backend code; dialyzer flags
   passing the opaque term outside `Expo`. The value is correct at runtime (the
   42-test suite passes), so it's a benign static-analysis false positive — **but
   `dialyzer` is part of this repo's `quality.ci` / `precommit` gate**, and
   AGENTS.md's release checklist requires "zero warnings/errors", so as merged the
   PR silently red-lit the gate and would block the next release. The module
   didn't exist before this PR, so the warning is newly introduced by it (the
   `ru` `nplurals=3` custom plural AST is what triggers it; the built-in
   `et`/`en` `n != 1` forms don't on their own).

   **Fix applied:** added `.dialyzer_ignore.exs` with a single targeted filter
   `{"lib/phoenix_kit_comments/gettext.ex", :call_without_opaque}` and wired
   `ignore_warnings` + `list_unused_filters: true` into the `dialyzer:` config in
   `mix.exs`. `list_unused_filters` keeps the ignore honest — if a future Gettext
   release stops emitting the warning, the gate fails on the now-stale filter so
   it gets removed. Post-fix: `Total errors: 2, Skipped: 2, Unnecessary Skips: 0`,
   `done (passed successfully)`.

2. **(Improvement — applied) Dialect-naming footgun for future locales.** Because
   the backend reads core's global locale and core stores the *resolved dialect*,
   a future catalog must be named by the dialect code, not the base code — e.g.
   German would need `priv/gettext/de-DE/…`, not `de`, or Gettext won't find it
   and the UI silently falls back to English. `ru`/`et` work only because the
   mapper maps them to themselves. This is non-obvious and easy to trip over, so
   a note was added to the `PhoenixKitComments.Gettext` moduledoc
   (`lib/phoenix_kit_comments/gettext.ex`). No behavior change.

3. **(Observation) The admin Settings page is not localized.** `web/settings.ex`
   / `settings.html.heex` contain **zero** gettext calls (all strings are
   hardcoded English) and were not rebound, so the comments module's own settings
   page stays English in every locale. This is a *pre-existing* state, not a
   regression — those strings were never wrapped in `gettext`. Translating it is a
   separate, larger change (wrap every string first, then extract/translate), so
   it's reasonably out of scope here. Recorded so the coverage gap is on record.

4. **(Observation) The whole module — not just "new" strings — now resolves to
   the comments backend.** Before this PR, shared words (Save/Delete/Cancel…) in
   these two modules resolved against core's catalog; now they resolve against the
   comments catalog. This is **not** a regression (all 117 strings were extracted
   and translated, so coverage is strictly greater than before), but it does mean
   the comments module now carries its own copies of common strings rather than
   reusing core's. Intentional and consistent with the "self-contained" goal.

## On tests

No automated test was added, consistent with the existing suite (unit-level
behaviour/callback/version introspection, no LiveView render harness, no DB
sandbox). The catalogs were instead validated mechanically as part of this review:
header/plural-form correctness, fuzzy/empty scan, full placeholder-integrity
check across all 117 entries, and a `--warnings-as-errors` compile that proves
every gettext msgid is a compile-time literal under the rebound backend. Pinning
rendered translations would require standing up a LiveView render harness with a
locale set per process — over-engineering relative to the suite's current stance.
Recording the deliberate skip here.

## Conclusion

A correct, well-executed i18n change. The risky part — rebinding gettext to a
second backend on top of `use PhoenixKitWeb` — was verified to work module-wide
via Gettext 1.0's attribute-based resolution, and the locale flows in for free
through core's global-locale convention. Catalogs are clean and placeholder-safe.
The one real defect was that the Russian plural form silently broke `mix dialyzer`
(and thus the release gate); that's fixed here with a targeted ignore filter, and
the full `precommit` gate now passes. The remaining durable caveat is the
dialect-naming requirement for future locales, now documented in the backend
moduledoc. Approve with the fix.
