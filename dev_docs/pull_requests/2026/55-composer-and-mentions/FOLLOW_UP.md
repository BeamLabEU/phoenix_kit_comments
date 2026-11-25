# PR #55 follow-up

Mention delivery rechecks the published body under a comment row lock. Deletion cleanup takes the same lock and rechecks the deleted status. Restore runs the publication check, including when a deleted comment goes back to pending. Integration tests cover stale bodies, hidden comments, and first delivery on restoration.

Recorder ids encode the component id for use in core's CSS selector. The two-thread test uses a component id containing a colon and checks that its Record command targets its own recorder. The rich-editor test submits from an always-open composer and checks the empty content sent to Leaf.

The lockfile updates db_connection to 2.10.3.

Optional calls dispatch through module arguments after capability checks. Switching resources resets the Leaf editor and replaces the plain textarea. A LiveView regression test covers the persistent rich editor across a resource switch.
