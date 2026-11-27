# PR #58 review

- **BUG - HIGH** Cancel cleared the reply text and GIF but left upload entries in the component. A later comment could include a file from the discarded draft.
- **BUG - HIGH** LiveView accepted an untyped recording by its extension. The component then passed an empty MIME type to storage, where a file row requires a MIME type. The upload test stopped after staging.
- **BUG - MEDIUM** The mention chip test required a Gravatar URL. With the locked PhoenixKit 3.9.0 dependency, a person with only an email rendered with initials and the suite failed.
- **IMPROVEMENT - MEDIUM** The PR introduced a crop-specific rendering branch on the moderation page. Its tests covered neither a handler-supplied crop nor the existing uncropped thumbnail.
- **BUG - MEDIUM** The reply form rendered uploads from a snapshot taken during the last component event. LiveView updated upload progress separately, so a staged file could remain invisible until the next click.
