# PR #45 — Document resource_links/0 as the way to make commented resources clickable

**Author:** Dmitri Don (mdon)
**Reviewer:** Claude (post-merge review, 2026-10-15)
**Verdict:** Approve. Docs only, and the documented behaviour is accurate. Two
small gaps in the README and one formatting nit, fixed here.

---

## What the PR does, checked against the code

Rewrites the resource-handler docs (README, `PhoenixKitComments` moduledoc,
`ResourceHandler` moduledoc, AGENTS.md) around `resource_links/0` on a
module's `PhoenixKit.Module`, with host config as the override. No code
changes. Every claim was checked against core's
`PhoenixKit.ResourceLinks` (2.62.2 in `deps/`):

- **"Three ways in, later ones winning per type."** `handlers/0` is
  `default_resource_handlers |> Map.merge(module_handlers) |> Map.merge(configured)`.
  Matches, including "config wins over module entries and built-ins".
- **"A template is a link only, no events."** `module_handlers` keeps only
  atom values; string and map values go to `module_templates/0`, which
  `handlers/0` never sees. The dispatch here (`Map.get(ResourceLinks.handlers(), type)`)
  therefore finds nothing for them. Matches.
- **Resolution order** (handler, module template, Settings template).
  `resolve_for_type/2` is a `cond` in exactly that order, and a handler that
  returns an empty map falls through, which is what "stopping at the first
  tier that answers" says.
- **Floor.** `resource_links.ex` is byte-identical between core `v2.38.0`
  and `v2.62.2` (`git diff --stat` empty), so the `>= 2.38.0` floor carries
  everything documented.

## Findings

### IMPROVEMENT - MEDIUM — README callback list omitted the reaction callbacks

The PR rewrote the opening of "Resource handler callbacks" to promise
"lifecycle notifications", but the list below it still named only
`on_comment_created`, `on_comment_deleted` and `resolve_comment_resources`.
`on_comment_liked/unliked/disliked/undisliked` (PR #23) have been in the
moduledoc and AGENTS.md since, but a README reader never learned they exist.
**Fixed:** added them, with the no-op rule.

### IMPROVEMENT - MEDIUM — Module templates and Settings templates differ in prefix handling, undocumented

Core treats the two template kinds differently: a module-declared template
is `prefixed: true` (`Routes.path/1` applied at render, `:prefix` left
alone), a Settings template is `prefixed: false` (used verbatim, `:prefix`
substituted). The PR documents both tiers but not this, and a module author
who writes `"/phoenix_kit/admin/widgets/:uuid"` gets a doubled prefix. This
is the same trap the AGENTS.md "raw paths" rule exists for.
**Fixed:** one paragraph in the README after the `resource_links/0` example.

### NITPICK — README example showed two `def resource_links` in one block

Copied whole, the block defines the same function twice with different
shapes. **Fixed:** the second is introduced with `# or, a link only …`.

### NITPICK — Rewrapped line left ragged in `resource_handler.ex`

The reworded "named by a module or in host config" sentence left one line
well past the wrap of its neighbours. **Fixed:** rewrapped.

## Not changed

- No test added. The PR is docs only and the behaviour lives in core, which
  tests it; a test here would only restate core's `handlers/0`.
- The `PhoenixKitComments` moduledoc does not repeat the prefix note; it
  points at the README/`ResourceHandler` for contract detail and the AGENTS.md
  convention already states "raw paths".

## Review coverage

Older PRs with no Claude review doc (#3, #4, #5, #7, #9, #14, #16, #17, #21,
#22, #25, #29, #32, #34, #39, #42) are not re-reviewed here; they merged
2–7 months ago, shipped in subsequent releases, and the later sweeps
(#31, #33-35, #41) already audited the code they touched.
