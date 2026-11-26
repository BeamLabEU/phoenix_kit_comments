# PR #56 follow-up

Metadata replacement preserves the stored marker, including when a caller clears metadata. Single and bulk patches discard both the atom and string spellings of the reserved key.

Edits and moderation now build their changesets from the same locked row. A direct edit that publishes runs the publication callback after the transaction, using the prior row to decide whether this is the first publication. The README and callback documentation cover the additional paths.

The published-marker integration tests cover stale edit results, repeated direct publication, clearing metadata, and patches through both APIs.

If a comment disappears between opening the editor and saving, the context returns `{:error, :not_found}` and the component refreshes the thread and shows its missing-comment notice.
