# Claude Review — PR #53

**Reviewers:** Claude Opus 5.5, with codex (GPT-6.1)
**PR:** Fix the Leaf comment composer offering no @ or # mentions (mdon)
**Reviewed:** 2026-11-19

The author's own review before opening. Codex read this diff together with the Projects PR that uses it, with numbered questions; each finding was checked against the code.

## Findings

### NOT A BUG — the host's `mention_people` is offered without core's search filter
A host passing people the viewer can't otherwise find would show them after `@` (codex). This is the attr's purpose: the host decides whom to offer. The one host (Projects) passes the task's people and the project's members, all of whom the viewer can already see on the project page.

### NOT A BUG — the warning names a mentioned account
The warning needs a valid mention token for that account, which the viewer only gets by picking the person from a list they could already see. The name shown is the one in the token.

### NOT REACHABLE — a suggestion request naming another composer's id
`{:leaf_suggest, …}` is a process message sent by the Leaf editor component of the same LiveView, not a client event. A browser can't address it to another component.

## Translations
The gettext merge had fuzzy-copied "Records" as the translation of the audio "Record". Both msgids are now filled by hand in all 8 locales, and no other entry changed.

## Verification
437 tests, 0 failures. New: `mention_suggestions_test.exs`, plus forwarding cases in `embed_test.exs`.
