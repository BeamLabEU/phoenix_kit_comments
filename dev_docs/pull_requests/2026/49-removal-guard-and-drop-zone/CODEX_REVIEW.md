# PR #49 — Attachment removal guard and drop zone

Reviewer: Codex. Reviewed 2026-10-30 against `6a7e1a3`.
PR: https://github.com/BeamLabEU/phoenix_kit_comments/pull/49
Author: Sasha Don (`alexdont`). Verdict: fixes applied.

Reviewed the merge diff, the current guard and hook, the core guard contract,
permission helpers, schemas and tests. Hidden and soft-deleted uses continue
to block removal; no release callback is added.

## BUG - HIGH — An unconditional behaviour breaks the supported build

The declared dependency range and locked PhoenixKit 3.0.0 do not provide
`PhoenixKit.Modules.Storage.RemovalGuard`. Declaring it unconditionally emits
both an unknown-behaviour warning and an invalid-`@impl` warning. That breaks
compilation with warnings as errors, including this repository's gate.

The behaviour and `@impl` attributes are now declared only when core supplies
the module. The guard's callable `places/2` API remains available on older
cores. README and module documentation explain that the media-browser
integration itself needs a core that implements removal guards. No dependency
pin is raised to an unpublished release.

## BUG - MEDIUM — A narrow moderator learns about unmanaged resource types

The old visibility check asked only for the base `comments` key. Since PR #47,
that key permits moderation only on the handler's managed resources. A media
dialog could therefore disclose that a file was attached to a comment on a
private resource type, even though the moderation page would hide that use.

The guard computes `moderation_scope/1` once per call and applies it to each
use. Out-of-scope attachments still return a blocking place, with nil label,
detail and href. When a file is shared by hidden and visible comments, it
names the oldest visible use instead of revealing the oldest hidden use.
Handler changes take effect on the next call. Tests cover narrow grants,
mixed visibility, revocation, full moderation, Owner and wildcard scopes.

## IMPROVEMENT - MEDIUM — A LiveView patch hides an active drop hint

The hook removed `hidden` on drag-enter, but the server always renders that
class. A patch during a drag could restore it; drag-over did not show the
hint again. Added `updated/0` on the JS hook to restore the hint from the
current nested-drag depth. Its regression simulates the server class patch.

The committed JS tests also cover nested enters/leaves, drop cleanup, text
drags, disabled/edit refusals, listener teardown and upload isolation between
two composers.

## Validation

- The original locked-dependency compile emitted both behaviour warnings;
  the fixed compile with warnings as errors succeeds.
- Regression execution against the original production modules fails the
  new scope, revocation and mixed-visibility checks.
- The drop-patch regression fails against the original shipped JS.
- Final suite and gate results are recorded in `FOLLOW_UP.md`.

The guard runs only when a host configures it and core asks it. Background
storage APIs remain governed by their own rules and the attachment foreign key,
as documented by core's contract.
