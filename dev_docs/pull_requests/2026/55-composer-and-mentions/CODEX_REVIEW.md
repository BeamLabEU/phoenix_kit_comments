# Codex review of PR #55

- **BUG - HIGH** Mention delivery trusted the status and text in the struct returned by a previous write. A slow callback could recreate a mention after deletion or quote text a moderator had already hidden. Cleanup could also run after restoration.
- **BUG - MEDIUM** Restoring a deleted comment with moderation disabled publishes it directly. Mentions in a previously held comment missed their first notification on this path.
- **BUG - MEDIUM** The recorder command builds a CSS selector from its DOM id. A colon in the host component id made that selector address a pseudo-class and broke the Record button.
- **IMPROVEMENT - MEDIUM** The rich-editor reset test opened a disposable composer and checked only the command name. It missed the persistent editor and the value sent to it.
- **BUG - HIGH** Hex reported advisory EEF-CVE-2026-133555 for the existing db_connection 2.10.2 lock.
- **BUG - HIGH** The warnings-as-errors build failed against the locked PhoenixKit 3.8.0. Elixir resolved both module variables to constants and warned about the two optional functions.
- **BUG - MEDIUM** Reusing an always-open component for a different resource left its client editor mounted with the old draft visible.
