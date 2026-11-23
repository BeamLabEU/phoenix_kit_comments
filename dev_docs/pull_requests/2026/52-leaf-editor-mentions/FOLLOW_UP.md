# Follow-up — PR #52

Grok, 2026-11-23. Claude's review of #52 and #53 stands. This file
records only the later pass.

## Fixed

- **Nil URL into `with_annotation/2`.** A file comment whose resolved
  URL is `nil` raised on `String.contains?/2` while the moderation chip
  rendered. The clause now requires a binary URL; `nil` stays `nil`.
  The unguarded call existed before the move. Test:
  `test/phoenix_kit_comments_test.exs`.
- **Stale comment above `status_badge_class/1`.** Left behind when
  `link_with_annotation/2` moved. Removed.

## Recorded on #53

#52 unescaped a forwarded draft and reply. #53's merge dropped that
call when it routed the assign through `put_draft/2`. Fixed and tested
there: `../53-leaf-composer-mentions/GROK_REVIEW.md`.
