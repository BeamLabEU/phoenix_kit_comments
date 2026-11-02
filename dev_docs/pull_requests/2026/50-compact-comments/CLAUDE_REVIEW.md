# PR #50 — Compact thread, order that follows the box, toasts and live times

**Author:** mdon (Max Don)
**Reviewer:** Claude (2026-11-02, merge `42835af`)
**Verdict:** Approve with fixes. The server side is sound: stable order, the
reaction gate, the numbered toast, and the avatar keyed on `attribution_mode`
rather than the name. The new chat-scroll hook, though, missed its main case:
a drawer opened on a short thread got bound to the page. It also jumped pages
whose thread was out of sight. That is fixed and tested against the shipped
bundle. One privacy point (Gravatar) is left open for a decision.

---

## What the PR does, checked against the code

- **Order follows the box.** `get_comment_tree/2` now orders by
  `inserted_at, uuid`, so two comments from the same instant never swap when
  the list is turned round. `display_order/2` reverses only the roots, and
  replies keep the order they were written in. With `effective_order/1` and
  `:auto`, the box at the bottom gives oldest-first; `:top`, `:both` and `nil`
  give newest-first. **Checked.**
- **Reaction gate.** `{:write, "toggle_…"}` is refused when `show_likes` is
  false. It sits after the `@write_events` gate, so a turned-off module still
  answers "Comments are turned off here." first. **Checked,** with the
  prefix-match caveat below.
- **Toasts.** An `:info` notice renders as a DaisyUI `toast`, a fixed-position
  button that fades out over 3.5 s through CSS and closes on click. The
  `notice_seq` in its id makes a second "Comment added" a new element, so
  the fade restarts. `:error`/`:uploading` stay inline. "Comment added"
  goes to `{:comment, uuid}` only for a published comment, and
  `put_notice/4` still falls back to `:thread` for a uuid that isn't in the
  tree. **Checked.**
- **Live times.** `PhoenixKitCommentsTimeAgo` rewrites the `<time datetime>`
  that core's `time_ago/1` renders (present with these attrs at the declared
  floor, core v2.38.0, as is `user_avatar/1` with `size="xs"`). It runs one
  shared 30 s timer and re-applies after every patch. An invalid locale
  throws a `RangeError` inside `try`, and the server's text stays.
  **Checked.**
- **Avatars.** A comment in project voice gets the project mark because
  `attribution_mode == "project"`, not because it has an
  `author_display_name` (personal comments have one too). **Checked.**

## Findings

### 1. BUG - MEDIUM — the chat-scroll hook missed the drawer it was written for and jumped pages (fixed)

`PhoenixKitCommentsStickToBottom` picked its scroller once, at mount, and
only accepted an ancestor that already overflowed. Otherwise it fell back to
`document.scrollingElement`.

- **A drawer opened on a short thread** (not scrolling yet) was bound to the
  page for good. At mount it scrolled the page behind the drawer to its very
  bottom. Once the drawer filled, new comments were never followed in the
  drawer, which defeats the hook's own description.
- **On a page** it scrolled to the *page's* bottom, past the thread to the
  footer and to whatever sits below it, even when the thread started below the
  fold.
- **A comment link** (`#…`) lost its place anyway. `stuck` started `true`,
  and the `ResizeObserver`'s mandatory first callback, on `observe()`, ran
  `toBottom`, bypassing the `location.hash` check.
- It also put a `scroll` listener on `window`, against the "nothing
  page-wide" rule for hooks.

**Fix** (`priv/static/assets/phoenix_kit_comments.js`): "the end" is now the
thread's end (the list plus the box under it, the hook element's parent), not
the scroller's bottom. The scroller is looked up each time it's needed.
Opening scrolls only if the thread starts in sight, and never for a `#…`
link. A patch follows if the end was in sight before it (`beforeUpdate`). A
resize follows if the end was in sight before the growth (current gap minus
growth), so the first observer call, which sees no growth, does nothing. The
hook no longer listens to scroll at all. Five Node tests in
`test/js/comments_hooks_test.cjs` model the browser geometry: drawer fills
later, reader scrolled back, page thread out of sight vs in sight, hash link,
destroyed before the first frame. All five fail against the merged bundle,
each on its own assertion.

### 2. BUG - MEDIUM (privacy) — every thread now sends commenters' email hashes to Gravatar (open: needs a decision)

The new avatar is core's `user_avatar/1`. For a user without an uploaded or
OAuth avatar, it renders `<img src="https://www.gravatar.com/avatar/<md5(email)>">`.
Before this PR the thread showed a generic icon. Now:

- every reader of every thread, public surfaces included, receives each such
  commenter's email MD5. That hash can be reversed by lookup for common
  addresses and links the person across sites. This module otherwise takes
  care never to show the address: the display-name chain never falls back to
  it, and moderation shows emails only under `comments.moderate_all`.
- every reader's browser requests `gravatar.com`, sending its IP and the
  page as referrer. That is a third-party transfer an EU host must justify
  or get consent for (the same shape as the Google Fonts rulings).

**Not fixed here.** Removing the email before the call turns every
Gravatar-only face into a "?" on a single gradient. The clean fix is an
option in core, a `gravatar={false}` attr on `user_avatar/1` or a site
setting, which core's own pages would want too. Then the thread passes it.
The maintainer should decide whether threads keep Gravatar until then.

### 3. IMPROVEMENT - MEDIUM — moving the box at runtime kept the old order (fixed)

The list is stored already turned round (`load_comments/1` →
`display_order/2`). But `update/2` reloaded only on a new `resource_uuid` or
on first load. A host that moved `composer_position` (or set `order`) on an
open thread kept the old order, while the template, which reads `chat?/1`
on every render, attached the chat-scroll hook to a newest-first list.

**Fix:** `reload_comments?/1` also reloads when `:order` or
`:composer_position` changed in this update. It's extracted from `update/2`,
which was at credo's complexity ceiling. Test: "a box moved while the thread
is open turns the list round with it" (test-host event `host_composer`).

### 4. NITPICK — the reaction gate matched a prefix, and had no test (fixed)

`handle({:write, "toggle_" <> _}, …)` refused every `toggle_…` write event,
not just reactions. Today that's only like/dislike, but a future write event
named `toggle_…` would have been dropped silently on every thread with
reactions off. Now it names `toggle_like`/`toggle_dislike`. The commit that
added the gate had no test. Added: "a reaction sent where the host turned
reactions off changes nothing" (test host `?likes=off`), which pushes both
events at the component and checks the counters.

### 5. NITPICK — `:order` was documented only in an inline comment (fixed)

Added `composer_position` and `order` to the component moduledoc's optional
attrs, and `order` to AGENTS.md's attr list. Shortening that list's
`composer_position` entry left AGENTS.md 12 bytes smaller (it is at
30,706 bytes; see the #42 review).

### 6. NITPICK — the plain textarea no longer grows outside Chromium (not changed)

`rows="1" field-sizing-content min-h-0` grows with its content where
`field-sizing` is supported. Elsewhere, notably Firefox, the box stays one
row and scrolls inside, though it can still be dragged larger. The plain
textarea is the fallback (Leaf off or not loaded), and the Leaf composer
sizes itself. Left as is: a JS autosize for the fallback is more than it's
worth. Noted so a "one-line box in Firefox" report has an answer.

## For the release notes (behaviour changes, not defects)

- Every thread with the box on top (the default) or with no box (`nil`,
  read-only) now lists **newest first**; before, every thread was oldest
  first.
- No card or shadow around the thread, no "(N)" count in the title, and no
  "No comments yet" line. Hosts that relied on the card for their panel now
  draw their own.
- Success messages are toasts (`position: fixed`). Inside an ancestor with a
  `transform` (a sliding drawer), they pin to that ancestor, not to the
  viewport.
