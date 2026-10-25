# PR #41 — Quality sweep recheck

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: fix required; applied with a regression test.

Reviewed the context and component changes, moderation wiring, metadata
filtering, JS hook registration, and current integration coverage. Earlier
follow-ups correctly route approval/restoration, preserve actor UUIDs, and
gate admin reads and writes. The stale approval/deletion weakness is covered
and fixed in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).

## BUG - MEDIUM — Explicit `enabled: true` bypasses the global off switch

`effective_enabled/1` returned every explicit host value directly. A host
passing `enabled={true}` therefore kept accepting comments after an admin set
`comments_enabled` to false. The live event gate used this same helper, so
rechecking at event time did not help. This contradicts the documented contract
that the host attribute is an additional off switch.

Reproduced through the real host LiveView: pass `enabled: true` with
`send_update/3`, disable the module, then submit the already-open component.
The regression test failed because a comment was inserted.

Fixed by consulting the module setting for both `nil` and `true`; `false`
continues to disable the thread. Rendering and event authorization share the
helper. Updated the public attribute documentation, which still claimed a
hardcoded `true` default. No context-level enabled gate was added: server-side
creation retains its separate contract.

See [FOLLOW_UP.md](FOLLOW_UP.md) and the #46 review for shared validation.
