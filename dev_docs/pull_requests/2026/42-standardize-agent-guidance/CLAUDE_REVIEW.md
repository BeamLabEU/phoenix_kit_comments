# PR #42 — Standardize AGENTS.md onto the shared module skeleton

**Author:** mdon (Max Don)
**Reviewer:** Claude (2026-11-02, against `main` at `f273a8f`)
**Verdict:** No findings. The two code changes still hold; the guide it
standardized has been rewritten since, so the review covers what is left of it.

---

## What the PR does, checked against the code

- **`version/0` single-sourced.** `@version Mix.Project.config()[:version]`
  (`lib/phoenix_kit_comments.ex`) replaces `Application.spec(:phoenix_kit_comments, :vsn)`.
  This is read at compile time. Mix pushes the dependency's own project
  while it compiles a dependency, so a host build gets this package's
  version, not the host's. Unlike the old `Application.spec/2`, it never
  returns `nil` when the app isn't started yet. A version bump edits
  `mix.exs`, and Mix recompiles the project whenever that file changes, so
  the value can't go stale. **Checked.**
- **Deterministic behaviour tests.** `setup_all` calls
  `Code.ensure_loaded!(PhoenixKitComments)` before the `function_exported?/3`
  assertions. Without it, random test order could leave the module unloaded,
  and `function_exported?/3` answers `false` for an unloaded module. **Checked;**
  the shape is still in `test/phoenix_kit_comments_test.exs`.
- **`CLAUDE.md` → `AGENTS.md` symlink.** Still in place; one guide.

## Notes, not findings

- AGENTS.md has been reshaped many times since (`59f8ea9` trimmed it to
  29,771 bytes to "stay under 30 KB"). PRs #49 and #50's follow-ups have since
  pushed it back to ~30.7 KB. The maintainer should decide whether that budget
  is 30,000 bytes or 30 KiB before the next addition.
- The guide's release section now says to tag "matching the form of the newest
  existing tag", which resolves the old bare-tag vs `v`-tag mismatch.
