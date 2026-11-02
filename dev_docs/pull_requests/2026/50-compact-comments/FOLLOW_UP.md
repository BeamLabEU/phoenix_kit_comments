# PR #50 — follow-up

Resolutions for the findings in `CLAUDE_REVIEW.md`.

- **1. Chat-scroll hook (BUG - MEDIUM): fixed.** `PhoenixKitCommentsStickToBottom`
  measures the thread's own end, looks up its scroller every time, opens at the
  end only when the thread starts in sight (never for a `#…` link), and follows
  a patch or a resize only when the end was in sight before it. It no longer
  listens to `scroll`. Five Node regressions in `test/js/comments_hooks_test.cjs`.
- **2. Gravatar (BUG - MEDIUM, privacy): open.** Needs a decision and a core
  option (`gravatar={false}` on `user_avatar/1`, or a setting). Nothing
  changed here.
- **3. Order after moving the box (IMPROVEMENT - MEDIUM): fixed.**
  `reload_comments?/1` reloads on a changed `:order` or `:composer_position`.
  Integration test via the test host's `host_composer` event.
- **4. Reaction gate (NITPICK): fixed.** Names `toggle_like`/`toggle_dislike`.
  Integration test via `?likes=off`.
- **5. `:order` docs (NITPICK): fixed.** Component moduledoc and AGENTS.md.
- **6. Plain textarea without `field-sizing` (NITPICK): not changed.**

## Verification

- `mix precommit`: passed (compile `--force --warnings-as-errors`,
  `deps.unlock --check-unused`, Hex audit, format check, strict Credo,
  Dialyzer). Test env also compiles with `--warnings-as-errors`.
- `node --test test/js/comments_hooks_test.cjs`: **19 tests, 0 failures**.
  The five new stick-to-bottom tests fail against the merged bundle
  (`COMMENTS_HOOKS_BUNDLE=<HEAD's bundle>`), each on its own assertion.
- `node --check priv/static/assets/phoenix_kit_comments.js`: passed.
- `mix test`: **88 tests, 0 failures, 179 excluded**. The shared test server
  (`postgres-test`) stayed in recovery mode for the whole session (20+ minutes
  of polling), so the integration suite did not run, including the two new
  integration tests (finding 3 and 4). They compile; run them, with the rest
  of `test/integration/`, once the server is back.
