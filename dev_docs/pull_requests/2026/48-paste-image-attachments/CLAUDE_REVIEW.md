# PR #48 — A pasted screenshot becomes an attachment instead of breaking the comment

**Author:** mdon (Max Don)
**Reviewer:** Claude (quality sweep on the open draft, 2026-10-29)
**Verdict:** Approve with fixes. Keeping the image out of the text is the right
fix, and so is sending it through the existing `:attachment` upload, which
already enforces type, count and size. But in three cases the paste still did
nothing visible: every refusal was a component flash nobody sees, the upload
could miss its input, and its failure path was unreachable. Those are fixed on
the branch (`3cbfd04`), with tests that fail against the PR's component.

---

## What the PR does, checked against the code

- `PhoenixKitCommentsPasteFiles` (`priv/static/assets/phoenix_kit_comments.js`)
  listens for `paste` in the capture phase on a wrapper round the composer's
  editor and the edit form's editor. It takes a paste only when the clipboard
  holds files and no text, renames generic screenshot names to
  `pasted-<timestamp>[-n].<ext>`, and either uploads the files or pushes
  `paste_refused` with a reason code. It is shipped via `js_sources/0` under
  the namespaced bundle and guarded against double registration. **Checked.**
- Pasted files go through the same `allow_upload(:attachment, …)` as the attach
  button. LiveView enforces `accept`, `max_entries` and `max_file_size`, and
  the errors render in the staged-media list. **Checked**, now with tests (below).
- `add_comment` refuses a body matching `data:image/…;base64,` before the
  precheck, and the old body moved unchanged into `create_comment_from/4`.
  **Checked:** a pure move.
- The catalogues: 4 new msgids, in `.pot` and en/et/ru, with et/ru filled.
  `mix gettext.extract --merge` adds and removes nothing, so every msgid in
  `lib/` is in the catalogue. The large diff is source-reference churn and
  removes no translation.

## Findings

### 1. BUG - HIGH — no refusal was ever shown (fixed)

`paste_refused` and the inline-image guard used `put_flash` inside
`CommentsComponent`. A LiveComponent's flash is copied to its parent only on
`push_navigate`/`push_patch` (`Phoenix.LiveView.put_flash/3` docs, "Inside
components"), and the component does not render its own `@flash`. The hook has
already called `preventDefault()`, so a paste with attachments off, or while
editing, just did nothing. The PR's test comment noticed that flashes never
reached the test layout but read it as a test-host limitation.

**Fix:** a `:composer_notice` assign, `{:composer | :edit, message}`, rendered
as `<p role="alert" data-composer-notice=…>` in the form it concerns. It is
cleared on typing, cancel, and opening another composer, reply or edit form.

### 2. BUG - HIGH — a paste could be dropped silently when there are two upload inputs (fixed)

`this.upload("attachment", files)` calls `dispatchUploads(null, …)`, which
searches the whole LiveView (`view.ts` `dispatchUploads`). If the page has two
open `CommentsComponent` composers, or the host has its own `:attachment`
upload, it finds two inputs, logs `upload.duplicate-input` and drops the files.

**Fix:** `uploadTo(<the wrapper's form>, name, files)` searches only that
form, and the form holds exactly one input.

### 3. BUG - MEDIUM — "attach_failed" could not happen (fixed)

`dispatchUploads` reports a missing or duplicate input with `logError` only;
it never throws. So the `try/catch` around the upload never fired, and
`paste_refused_message("attach_failed")` was dead code.

**Fix:** the hook looks for its form's input first and pushes `attach_failed`
when it is not there. The `catch` stays for a genuine throw.

### 4. BUG - MEDIUM — `paste_refused` without a reason killed the host LiveView (fixed)

Only `%{"reason" => _}` matched, so an empty payload raised
`FunctionClauseError` in the component, which runs in the host's process. Its
sibling `audio_recording_error` was hardened against the same shape. **Fix:** a
fallback clause that shows the generic refusal.

### 5. IMPROVEMENT - MEDIUM — the inline-image guard covered new comments only (fixed)

`save_edit` had no `inline_image?` check, so a browser with the old script
cached still wrote the image into an edit's text. That fails with "exceeds
maximum length" when large, and is saved into the text when small. **Fix:** the
same guard in `do_save_edit/3`, with the edit wording ("Files can't be added
while editing a comment…").

### 6. IMPROVEMENT - MEDIUM — cross-dimension tests missing (fixed)

Before: a wrapper-attribute check, one refusal reason sent without asserting
its message, and the new-comment guard. Added (`test/integration/comments_component_test.exs`, "a pasted file"):

- the wrapper renders only with the composer open
- `data-attachments` and the file input match the setting (on/off), for both
  the composer and the edit form
- each refusal reason is shown in the right form, plus a missing reason
- typing clears the refusal
- through the composer's upload: one image, several files, a refused type,
  over the count cap, over the size cap
- the inline guard on a new comment and on an edit

Text + image, the naming, and the scoped upload are browser-only, so LiveViewTest
cannot run them. They were exercised with a throwaway node harness against the
bundle, which is not committed: one image, several (`-2` suffix), a PDF, text +
image (left alone), attachments off, editing, and a form with no input
(`attach_failed`).

### 7. IMPROVEMENT - MEDIUM — the docs did not mention the hook (fixed, `ba7b20f`)

AGENTS.md's JS-hooks section now lists `PhoenixKitCommentsPasteFiles` and the
paste rules, and adds a landmine for the component-flash trap. The README
gains "Pasted files".

### 8. NITPICK — et/ru `.po` lost their final newline (fixed)

A hand edit. Restored by `mix gettext.extract --merge`.

## Not changed — for the author

- **NITPICK:** the guard also refuses a comment that only quotes
  `data:image/png;base64,` as text, for example in a code block. Narrowing it to
  `](data:image…` and `src="data:image…` would keep what the editor produces
  and let text through.
- **NITPICK:** `data:image/svg+xml;utf8,…` is not matched. That is harmless for
  the length problem the guard exists for.
- **Design:** the guard sits in the component, not in `create_comment/4` /
  `update_comment/3`. A host or API caller can still store a data URL within
  the length limit.
- **NITPICK:** ru "Попробуйте кнопку вложения" reads clipped; "Воспользуйтесь
  кнопкой вложения" is smoother.

## Outside this PR (pre-existing)

- **BUG - HIGH:** the other 31 `put_flash` calls in `CommentsComponent` have the
  same problem as finding 1, so none of them is ever seen ("Comment can't be
  empty", "Wait for uploads to finish.", the length and permission refusals…).
  The fix is the same idea for the whole component: render its flash, or a
  notice assign, in its own markup, and clear it.
- **BUG - MEDIUM:** the voice recorder has finding 2's unscoped
  `this.upload(...)` (`phoenix_kit_comments.js:78`), and its start/stop button
  sends a `window`-wide `phx-kit-comments-audio-toggle` event that every
  recorder hook on the page answers. So with two open composers, both record.

## Verification

- `mix test`: 203 → 217 tests, 0 failures (DB-backed, 0 excluded).
- `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused,
  hex.audit, format, credo --strict, dialyzer): passes.
- Code against catalogue: `mix gettext.extract --merge` reports 0 new and 0
  removed in en/et/ru; et/ru have no empty `msgstr`.
- Browser: not driven (visual baseline skipped for this sweep). The hook was
  checked with the node harness described in finding 6.
