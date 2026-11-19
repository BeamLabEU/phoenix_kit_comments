# Codex review of PR #54

Reviewed the mention-chip renderer against the locked PhoenixKit 3.6.1, including core token parsing, account resolution, avatar selection, and the component's cached bodies.

- **BUG - MEDIUM** Core's token splitter removes the escape from a literal mention. When a real chip was present, the subsequent markdown resolution could turn that literal into a live mention.
- **BUG - MEDIUM** The account lookup used the trigger and UUID alone. An @ token for another resource type could receive a person's avatar if the two records shared a UUID.
- **BUG - MEDIUM** In a link destination, substituting the HTML-escaped name after sanitization allowed punctuation in the resolved name to change the URL's query parameters.
- **BUG - MEDIUM** The locked core derives avatar initials from email and lacks the newer avatar name attribute. The PR's initials assertion failed. Core also falls back to external image providers, which made a mention in the comment body initiate a third-party request.
- **IMPROVEMENT - MEDIUM** Substitution scanned each text or tag fragment once per distinct mention. A single placeholder scan with map lookups removes the repeated scans.
