# PR #47 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewers:** codex (both rounds); the design was agreed with codex, grok, zai and kimi first; findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

The sweep's rules: a sub-key `<base>.<sub>` is checked with `Scope.can?/2` in `mount/3` and every write
event against the live scope; new sub-keys are backfilled once to current base-key holders, with the
flag set only after every grant succeeded. Round 1 reviewed the whole change, round 2 only the fixes.

## Findings

- BUG-MEDIUM — the in-thread delete (and edit) still let the Owner/Admin role act on anyone's comment → fixed: author or `may_moderate_resource?/3`.
- BUG-MEDIUM — author email visibility was decided at mount → fixed: from the live scope at render.
- BUG-HIGH (round 2) — hosts that pass no `pk_scope` (CRM, projects) kept the scope built at first update, so a revoke never reached edit/delete → fixed: write events authorise against a scope read at the event.
- NITPICK — a resource-handler test was true by definition → replaced.
