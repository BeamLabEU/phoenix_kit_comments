# PR #38 — Codex review

**Reviewer**: Codex (gpt-5.6, `codex exec`, repo-anchored)
**Scope**: The single commit
**Date**: 2026-08-24
**Method**: Read the diff and the module; concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

- [comments_component.ex:961](<phoenix_kit_comments/lib/phoenix_kit_comments/web/comments_component.ex:961>) — A subscribed host receives `:updated` twice: `update_comment/3` broadcasts through PubSub, which includes the sender, then line 971 directly sends the identical message to `self()`. This can trigger duplicate reloads or side effects. Fix: use `broadcast_from` to exclude the caller while retaining the direct host notification.

No other concrete defects found. The update broadcasts after `Repo.update/1` returns, the new message contract is documented, and `broadcast: false` is covered at [edit_broadcast_test.exs:43](<phoenix_kit_comments/test/integration/edit_broadcast_test.exs:43>). Tests were not run.
75 302
- [comments_component.ex:961](<phoenix_kit_comments/lib/phoenix_kit_comments/web/comments_component.ex:961>) — A subscribed host receives `:updated` twice: `update_comment/3` broadcasts through PubSub, which includes the sender, then line 971 directly sends the identical message to `self()`. This can trigger duplicate reloads or side effects. Fix: use `broadcast_from` to exclude the caller while retaining the direct host notification.

No other concrete defects found. The update broadcasts after `Repo.update/1` returns, the new message contract is documented, and `broadcast: false` is covered at [edit_broadcast_test.exs:43](<phoenix_kit_comments/test/integration/edit_broadcast_test.exs:43>). Tests were not run.
