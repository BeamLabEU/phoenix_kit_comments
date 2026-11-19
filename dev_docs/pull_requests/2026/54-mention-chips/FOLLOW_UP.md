# PR #54 follow-up

The renderer selects matching account tokens by both kind and resource type, and substitutes chips in the original source so escaped tokens survive until markdown rendering. URL attributes receive percent-encoded names. Text and descriptive attributes retain the readable name.

Mention chips use the stored profile image when available and derive fallback initials from the resolved display name. Integration tests cover both branches, literal mentions mixed with chips, coincident resource and account UUIDs, punctuation inside a query value, and switching a mounted thread to withheld titles. The escaping test uses a resolved account name containing markup, and the placeholder test exercises a body with a real chip.
