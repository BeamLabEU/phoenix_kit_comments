# Quality sweep — phoenix_kit_comments (2026-11-08)

Reviewer: Claude

A whole-library review after the translation pass (`a28a07f`). Five read-only
reviewers covered the context API, the comments component and renderer, the
admin LiveViews, the data layer and JS hooks, and the docs and test suite.
Each was given AGENTS.md and the August sweep's "Rejected" and "Open" lists.
**Every finding below was checked against the code, most by running it,
before it was fixed.** The fixes were then made in three parallel streams with
strict file ownership: context and data, admin pages, component.

Result: 416 tests (up from 303), 0 failures (4 skipped: voice notes need a
newer core than the locked 3.4.0); `mix precommit` clean; `mix docs` without
warnings.

## Fixed

### Critical / high

- **One crafted comment crashed every render of its thread** (component).
  `client_metadata/2` passed nested values through, and the renderer put
  `metadata["annotation_uuid"]` into an attribute: `metadata[annotation_uuid][x]=y`
  raised `Protocol.UndefinedError` for the poster and every later visitor,
  including the dead render, and survived a delete once replied to. Client
  metadata now keeps string values only, and the attribute renders only a
  string, so rows already stored render again.
- **The markdown sanitiser left `style` and `class` on `span`, `code` and
  `pre`** (and `class` on `div`). A comment could draw a fixed full-page
  overlay with inline CSS or the host's own classes (`toast`, `alert`,
  `fixed inset-0`) on every reader's page and on the moderation page. Both
  attributes come off all four tags.
- **Bulk moderation was unreachable from the UI.** The bar sat outside
  `<.bulk_select_scope>`, and core's hook only looks inside its own element,
  so the bar never showed (since July). The tests pushed the events directly.

### Moderation and data integrity (context)

- **Status transitions are decided on the locked row.** All of them, single
  and bulk, go through one `transition_locked/2`:
  - hide refuses a deleted comment (it used to undelete it into `hidden`,
    one click from Approve);
  - restore refuses one that is not deleted (a crafted restore published a
    hidden comment);
  - delete refuses an already-deleted one (a stale tab or a mixed bulk
    selection re-fired `on_comment_deleted`, wrote another audit row and
    broadcast again);
  - a transition to the current state has no side effects.
- `bulk_update_status/3` routes each row through the matching single-row
  function. It published deleted comments, skipped `on_comment_published`
  and logged `comment_updated` for an approval.
- **FK constraint names** in the three changesets now match the database
  (`fk_comments_*`). Under Ecto's defaults a missing author or comment raised
  `Ecto.ConstraintError` out of `create_comment/4` and `like_comment/2`.
- **Reaction deadlock.** `like_comment` deleted the dislike row before locking
  the comment, and `undislike_comment` locked first: 29 of 40 concurrent pairs
  deadlocked, crashing the LiveView. Every reaction path now locks the comment
  first. A switch fires both callbacks (`on_comment_undisliked` was never
  sent). A failed insert rolls back instead of reporting `:already_liked`.
  Counters clamp at zero instead of skipping the decrement.
- **NUL bytes** in a body, metadata or labels raised from Postgres (any
  commenter could crash the host page). They are now a changeset error
  (`validation: :null_byte`) or `:invalid_content`, and are dropped from a
  search.
- **A reply to a comment on another record** was stored where neither thread
  shows it. It is now refused (`:invalid_parent`), as is a malformed parent.
- **`update_comment/3` could move or re-sign a comment**: it used the create
  changeset, which casts the author, resource, parent and depth. A new
  `Comment.update_changeset/3` casts content, metadata and status only.
- **String-keyed attrs** to `create_comment/4` raised (mixed keys). They now
  work for the client-safe fields only, so forwarded params can never set
  `:status` or `:inserted_at`.
- `list_all_comments/1`: `per_page: 0`, a negative value or a 20-digit page
  raised; a malformed user filter listed everyone's comments. Both are fixed.
- PubSub topics and payloads lower-case the resource uuid: a create used the
  caller's spelling, so a lower-case subscriber missed it.
- Settings readers all rescue and `catch :exit` (three did not, and run in
  the component's mount). `moderation_enabled?/0` added. The Giphy rating is
  whitelisted on read.

### Leaks into logs

- A resource handler that raised logged `inspect(error)`, and a
  `MatchError`/`CaseClauseError` carries the comment, body included. The exit
  path did the same through the inner `GenServer.call` reason. Both now log
  the shape only, and so do the reaction and broadcast guards.

### Component

- An edit re-reads the comment and refuses one deleted or hidden meanwhile
  (it used to save new text into a deleted row and send @-pings). The reply
  target is re-checked at submit. The reply and edit state resets when the
  host points the component at another record.
- A rejected staged file left "Wait for uploads to finish." on screen
  forever. A double-clicked ✕ on a staged file crashed the page. A decoration
  label reached the host even when the body edit was refused.
- A catch-all event clause: 11 malformed or unknown events crashed the host.
- With moderation on, the poster is told the comment awaits approval.
- **Each comment body is rendered once per load, not on every keystroke**
  (60 → 0 markdown renders for 20 comments × 3 keystrokes).
  - The same move fixed `withhold_mention_titles`, which had been a no-op:
    the function component could not see the scope, so a locked mention
    printed its title.
- `composer_position: nil` is now read-only as documented (hosts use it for
  previews; Reply still worked). `rich_text` is re-read on every update. An
  editor id containing ":" works. Changeset errors are shown in words, not raw
  `%{count}` English.

### Admin pages

- **Path templates.**
  - Templates must pass `Routes.local_path?/1`: `//evil.example/:uuid` became
    an off-site link, and a `javascript:` form crashed the moderation page.
  - Adding or removing a template no longer overwrites what another admin
    saved meanwhile.
- **Settings save.**
  - One `update_settings_batch/2` transaction carrying the actor (history
    said "system").
  - A blank Giphy key on a site that never stored one used to fail every save.
- **On/off switch and Reset.**
  - The switch is written only when changed, so a stale page can't switch
    comments back on, and the change is broadcast.
  - Reset no longer switches the module off or erases the Giphy key.
- **Pagination.** The page is clamped to the last page, and an overflowing
  page number no longer crashes the page.
- **Crafted URL or event params** of the wrong shape no longer crash either
  page.
- Smaller fixes:
  - The "types without link patterns" list skips types a handler already
    links.
  - A bulk selection with vanished rows counts them as failures.
  - Email visibility is computed once per render.
  - The Giphy key field uses `autocomplete="new-password"`.

### Data layer, JS, tooling

- **Removal guard.** It asks no handler for a file no comment uses (it asked
  every handler on every media-library trash), and shows the type humanised.
- **Migration prefix.** It must be lower case, as core's helpers require: a
  mixed-case one could not be re-run, and its version read 0.
- **JS hooks.**
  - Time-ago picks its unit from the rounded value ("60 min. ago" →
    "1 hr. ago").
  - A dropped desktop file keeps its name.
  - A dead class toggle is removed.
- **The JS tests are in the gate** (`test/js_hooks_test.exs`), skipped
  without node.
- **Docs.**
  - AGENTS.md and the core-pin test still documented the old
    `>= 2.38.0 and < 3.0.0` pin, which an agent following them would have
    restored.
  - The README never said to run `mix phoenix_kit.update` (core 3.x no longer
    creates the tables), and claimed a unique reaction index that does not
    exist.
  - The component documented 6 of its 18 optional attrs.
  - The `forward_leaf_event/2` example returned `:pass` from `handle_info`.
- **Test suite.**
  - Tautological tests (`is_boolean`, `function_exported?`) were replaced by
    behaviour tests against rows (`module_config_test.exs`).
  - DataCase now imports the activity assertions its docs promised.
  - The test router serves the path `push_patch` resolves to, so filter and
    search are tested at last.
  - A stale test database now reports why it can't be used.

## Rejected after verification

- **"Content-type trust in `store_entry`."** Core sniffs the bytes
  (`Storage.content_mime_type/3`) and serves non-runnable types as downloads
  with `nosniff`. Only the comment was wrong, and it is corrected.

## Decided (follow-up, same day)

The three decisions above went the recommended way:

1. **Inline images.** An `<img>` stays only from this site (relative, or its
   own host) or Giphy over HTTPS; any other becomes a link to it, so showing
   a comment never makes a browser fetch a third party's image.
2. **Replies under a hidden parent.** A hidden or pending parent is kept as a
   `[removed]` placeholder while it has published replies, as a deleted one
   was. Its body and media are blanked in `get_comment_tree/2` itself, so a
   taken-down text never reaches a page. The replies show again, and the
   count matches what is shown.
3. **Status from params.** Neither changeset casts `status`;
   `Comment.put_status/2` sets it, from atom-keyed server code only. A
   forwarded edit can no longer un-hide a comment, nor a forwarded create
   skip the queue.

## Open — known gaps

- **No database-level uniqueness for reactions.** Adding it is a V2 of this
  module's chain: de-duplicate first, and use the changesets' names
  `uq_comments_{likes,dislikes}_comment_user`.
- **No HEEx formatter.** `.formatter.exs` has no
  `Phoenix.LiveView.HTMLFormatter`, so templates are never formatted. Adding
  it is a whole-template churn commit of its own, best checked for
  whitespace-sensitive output (`<textarea>`).
- **Voice-note tests** skip against the locked core 3.4.0; they need a core
  with the recorder seam.
- **Error strings** are still spread over four private functions (the
  August "Errors module" item). The new ones have tests; most of the old
  create-error clauses still do not.
