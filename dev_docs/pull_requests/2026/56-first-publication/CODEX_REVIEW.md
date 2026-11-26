# PR #56 review

- **BUG - HIGH** A null metadata replacement could erase publication history. The single-row and bulk JSONB patch APIs could also overwrite it. An edit could therefore suppress a first announcement or repeat an earlier one.
- **BUG - MEDIUM** The edit transaction read only the marker. A caller editing an older struct could get a successful result with an obsolete status, which also fed the audit log.
- **BUG - MEDIUM** A server-side edit setting the status to published consumed the marker without calling the publication handler. Later approval could never announce that comment.
- **IMPROVEMENT - MEDIUM** The host callback documentation described approval from pending as its sole trigger. Hosts also need to account for publication through restore or a direct status update.

**Legacy limitation.** For comments without a publication marker, the stored status is the only evidence of prior publication. An already-published comment requeued before the upgrade can receive one more announcement on approval.
