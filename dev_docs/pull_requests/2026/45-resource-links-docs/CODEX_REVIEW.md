# PR #45 — Resource link documentation recheck

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: no new correctness findings.

Checked the documentation against core's actual `ResourceLinks.handlers/0`,
module resolver filtering, and resolution branches, plus this module's event
dispatcher. Host config overrides module handlers, which override built-ins.
String/map module entries are templates, not event handlers. Resolution tries
the handler, module template, then Settings template.

The README's prefix distinction is accurate: module templates are internal
routes prefixed at render time, while Settings templates are rendered as URLs
with explicit `:prefix` substitution. The callback lists now include reactions
and #46's published callback. No additional runtime change or redundant test
was needed for this documentation PR.

Shared validation is recorded in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).
