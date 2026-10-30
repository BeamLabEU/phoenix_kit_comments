# PR #48 — Paste uploads, notices and attachment references

Reviewer: Codex. Reviewed 2026-10-30 against `6a7e1a3`.
PR: https://github.com/BeamLabEU/phoenix_kit_comments/pull/48
Author: Max Don (`mdon`). Verdict: fixes applied.

Reviewed the merge diff and current context, including the upload precheck,
component notice placements, client metadata filtering, scoped audio/paste
uploads, file-reference registration and core's orphan finder. The previous
Claude review remains unchanged.

## BUG - HIGH — The attachment predicate ignores schema prefixes

`FileReferences.pairs/0` used a raw `FROM phoenix_kit_comment_media`. Ecto
prefixes its schemas but cannot qualify a table name inside SQL text. In a
prefixed install, the predicate therefore reads public media or fails when
that table is absent. Reading an unrelated public table can classify a live
attachment as an orphan.

The predicate now wraps a schema-backed `CommentMedia` subquery, preserving
the correlated `NOT EXISTS` check and its indexed lookup. It honors both the
schema's configured prefix and a query's inherited prefix. Added a generated
SQL assertion and a scratch-schema integration case with two files, one
attachment, and an unchanged search path.

Core 3.0.0 still has public-only optional-table discovery and other unqualified
predicates in its orphan finder. Those are separate core limitations; this
fix covers the predicate supplied by comments, not complete prefixed-core
orphan-finder support.

## BUG - MEDIUM — Cancelling a composer can leave a late microphone running

While checking the recorder changes, found a pre-existing lifecycle race:
`getUserMedia()` can resolve after the hook has been destroyed. The old hook
then started recording and retained a microphone stream that no active form
owned. Repeated starts while permission was pending could also create several
streams. Destroying an active recorder stopped tracks without stopping the
recorder or suppressing its final asynchronous events.

The hook now tracks pending starts and destruction, releases late streams,
stops active recorders and ignores events from discarded recorders. Normal
recordings still upload into their own composer. It also reports unsupported
`MediaRecorder` and recorder-start failures through the existing translated
reason codes, releasing the stream on failure.

## IMPROVEMENT - MEDIUM — Keep executable tests for the shipped hooks

LiveView tests check the rendered targets and upload rules but do not execute
JavaScript. Added a dependency-free Node test suite against the actual bundle:
scoped uploads and toggles, screenshot naming, text-plus-image pastes,
refusals, missing inputs, hook teardown, pending permissions, recording
completion and startup errors. The same suite exercises PR #49's drop path.
The command is documented in README; no Node dependency is added to Mix.

## Validation

- The regression runner recompiles original production modules in a separate
  VM; the new prefix and privacy cases fail against the original sources.
- Five lifecycle/drop regression cases fail against the original JS bundle.
- Final test and gate results are recorded in `FOLLOW_UP.md`.
- Browser hardware and visual rendering are not exercised by the Node tests;
  browser APIs and DOM events are simulated.
