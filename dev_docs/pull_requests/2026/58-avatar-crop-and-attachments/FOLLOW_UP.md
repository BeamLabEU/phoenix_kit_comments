# PR #58 follow-up

- Cancel now clears every staged upload using the same cancellation logic as a resource change. A LiveView regression test stages a file on a reply, cancels it, and opens a fresh composer.
- Storage receives a MIME type derived from the accepted extension for empty or generic browser types. A specific browser type takes precedence, so an audio recording identified as audio/webm keeps that type. Tests cover an untyped WebM, a spreadsheet, a typed recording and an unlisted extension.
- The mention test checks the inline chip and initials across supported core renderers. The separate stored-avatar test still checks for the person's own image.
- A moderation LiveView test exercises both thumbnail branches through a registered resource handler.
- The reply renderer now reads the current upload assign. The cancellation regression also checks that the filename appears immediately after upload.
