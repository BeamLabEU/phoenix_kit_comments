# PR #49 — Codex review follow-up

- **Supported-core compile:** feature-detect the optional removal-guard
  behaviour before declaring it or its callback annotation. Document which
  core capability the browser integration requires.
- **Label privacy:** compute one fresh moderation rule per request; hidden
  uses block removal without exposing their resource type. Prefer a visible
  use for shared files, and honor handler revocation on the next call.
- **Drop hint:** reapply the active drag hint after LiveView patches.
- **Regression coverage:** extend the removal-guard integration tests and
  commit a Node suite that executes the shipped paste/drop/audio hooks.

Updated AGENTS.md and README for the permission and compatibility contracts.
The changes do not alter the release version, changelog or migration chain.

## Verification

- Full database-backed suite: **255 tests, 0 failures, 0 excluded**, using
  the locked Hex PhoenixKit 3.0.0 and isolated PostgreSQL 18.
- Focused reference/removal tests: **23 tests, 0 failures**; the original
  production modules produce **5 failures** with these regression tests.
- Shipped JS bundle: syntax check passes; **14 Node tests, 0 failures**.
  Five selected regressions fail against the original bundle.
- `mix precommit`: passed, including compilation with warnings as errors,
  dependency checks, Hex audit, formatting, strict Credo and Dialyzer.

Node tests simulate browser APIs; no physical microphone or browser visual
test was run. The compatibility build covers the locked core without the
optional guard behaviour; integration with core's newer media-browser guard
dispatcher was checked against its source contract, not run on that core.
