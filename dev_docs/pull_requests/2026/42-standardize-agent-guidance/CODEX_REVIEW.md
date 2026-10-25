# PR #42 — Agent guidance and version consistency

Reviewer: Codex. Rechecked 2026-10-25 against main at `267885a`.
Verdict: no new correctness findings.

Although predominantly documentation, the merge also single-sources
`PhoenixKitComments.version/0` from `Mix.Project.config()[:version]` at compile
time and explicitly loads the module before callback-export assertions.
Checked both changes and the current behaviour tests. The runtime version no
longer depends on the application already being started; the compiled value
matches the package's `mix.exs` version. Loading before `function_exported?/3`
removes a real test-order dependency. No release bump was needed in this review.

Shared validation is recorded in [the #46 review](../46-on-comment-published/CODEX_REVIEW.md).
