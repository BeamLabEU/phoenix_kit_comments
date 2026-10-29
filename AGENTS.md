# AGENTS.md

Guidance for AI agents working on `phoenix_kit_comments`.

## Overview

Polymorphic commenting for PhoenixKit hosts: nested threads, reactions, Giphy,
attachments, voice notes, markdown, moderation, activity logs and PubSub updates.
Comments attach by `(resource_type, resource_uuid)` without a resource FK.
`PhoenixKitComments` implements `PhoenixKit.Module` and the context API;
`Web.CommentsComponent` embeds threads; two admin LiveViews cover moderation
and settings. This library uses the host's endpoint, router, repo and PubSub.

- **Depends on:** `phoenix_kit` `>= 2.38.0 and < 3.0.0` (Hex — the release that carries `PhoenixKitWeb.Actor`, `Activity.log/3` and `Storage.ResourceFolders`; the compound form keeps the ceiling open across later 2.x minors), `phoenix_live_view` `~> 1.1`, `giphy_api` `~> 0.1.1`. MDEx is used directly but NOT declared: core provides it transitively so every module shares one resolved version; never add a direct `mdex` dep. No sibling module deps. Newer core seams (`PhoenixKit.Mentions`, `PhoenixKit.Settings.get_editor_mode/0`) are probed with `Code.ensure_loaded?/1` and degrade to off.
- **Admin surface:** tab `:admin_comments` at `/admin/comments` (moderation dashboard; group `:admin_modules`, `match: :prefix`); settings subtab `:admin_settings_comments` at `/admin/settings/comments` (parent `:admin_settings`). The moderation tab carries `permission: "comments"`, the settings tab `permission: "comments.settings"`.
- **Module key** `"comments"`; settings prefix `comments_`.

## Boundaries

- Never reference the resource's table; link only by `(resource_type, resource_uuid)`.
- Resource titles and links delegate to core's `PhoenixKit.ResourceLinks`; `comment_resource_paths` is a core setting.
- Handlers decide whether to skip self-action reaction notifications.
- Decoration edits pass `actor_uuid` to the host, which must authorise its own record.
- Hosts register Leaf's bundle and core's `MentionInput`; this module ships neither and uses a plain `<textarea>` when Leaf is off.

## Commands

```bash
mix deps.get
createdb phoenix_kit_comments_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`PHOENIX_KIT_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- Module key `"comments"` in every callback; tab ids `:admin_comments` and `:admin_settings_comments`; URL segment `comments` on both tabs; setting keys prefixed `comments_`.
- Paths go through `PhoenixKit.Utils.Routes.path/1`, never hardcoded or relative. A handler's `resolve_comment_resources/1` returns RAW paths without the URL prefix; the renderer applies `Routes.path/1` once, so a pre-prefixed path doubles.
- Routing: `live_view:` on both tabs; no `route_module/0`. Core compiles the routes into `live_session :phoenix_kit_admin`; never hand-register them in a host router. Reference: core's `guides/custom-admin-pages.md`.
- LiveView macros: `use PhoenixKitWeb, :live_view` (Index, Settings) and `use PhoenixKitWeb, :live_component` (CommentsComponent), each immediately followed by `use Gettext, backend: PhoenixKitComments.Gettext`. The order matters: the second `use` rebinds the `gettext` macros from core's backend to this module's. Templates never wrap in `LayoutWrapper`; `Web.Markdown` is a plain `Phoenix.Component`.
- Gettext: own backend `PhoenixKitComments.Gettext`, catalogs in `priv/gettext` (`en`, `et`, `ru`, domain `default`). `mix gettext.extract --merge` regenerates them. A new locale is named by the dialect core resolves to (`de-DE`, not `de`; `ru` and `et` map to themselves). Tab labels are plain strings translated by core through the Tab's `gettext_backend:`/`gettext_domain:`, so a label's msgid must exist in the catalog: anchor it with a `gettext("…")` call somewhere in `lib/` or it never enters the pot.
- JS hooks ship as the prebuilt bundle `priv/static/assets/phoenix_kit_comments.js`, folded into the host `LiveSocket` by core from `js_sources/0` under the global `PhoenixKitCommentsHooks`. Never register a hook from an inline `<script>`: a hook has to be in the LiveSocket when it is constructed, and morphdom does not execute inserted script tags, so an inline hook vanishes on LiveView navigation (`unknown hook found for "…"`). Hook names are namespaced (`PhoenixKitCommentsAudioRecorder`, `PhoenixKitCommentsPasteFiles`, `PhoenixKitCommentsInsertAtCursor`) because the fold into `window.PhoenixKitHooks` is last-write-wins across every module's bundle and core's own hooks.
- Pasted files (`PhoenixKitCommentsPasteFiles`, a wrapper round the composer's and the edit form's editor, capture-phase `paste` listener): a paste carrying files and NO text becomes the comment's attachments through the same `:attachment` upload as the attach button (same type/count/size limits); a paste with text is left to the editor (Word and Excel put a picture of the cells next to the text). Where nothing can be attached (`data-attachments` not `"true"`: attachments off, or an edit) it pushes `paste_refused` with a reason code, never lets the editor write the image into the text. The upload goes through `uploadTo(<the wrapper's form>, …)`, never `upload/2`, which searches the whole LiveView and drops the files when a host page has two open composers. The server also refuses a body (new or edited) carrying a `data:image/…;base64,` URL — a browser with the old script cached.
- Voice notes (`PhoenixKitCommentsAudioRecorder`, one per composer form): the start/stop buttons fire `JS.dispatch("phx-kit-comments-audio-toggle", to: "#<recorder id>")` on that composer's own recorder element (`recorder_id/2`, carries `@myself`), and the finished recording goes through `uploadTo(<its form>, …)`. Rule for every hook: nothing page-wide — no `window` events, no `document` lookups, no `upload/2` — because a host page can show several threads at once (a window-wide toggle made one click record in every open composer).
- Messages from `CommentsComponent` go through `put_notice(socket, place, kind, message)`, never `put_flash` (a LiveComponent's flash reaches the page only when it navigates, and this one never does; a `put_flash` followed by `push_navigate` would be the only exception). One `:notice` assign, `{place, kind, message}`, rendered where the person is looking: `:composer` (the open new-comment or reply form), `:edit` (the edit form), `{:comment, uuid}` (under that comment; a uuid not in the tree falls back to the thread), `:thread` (top of the thread). `kind` is `:error`, `:info`, or `:uploading` (shown only while an upload is running, so it clears itself). `handle_event/3` clears the notice before every event except `update_comment_draft` (an error stays while it is being typed away), so a notice lasts until the person's next action; the ✕ sends `dismiss_notice`. No timers. A new event handler is a `defp handle/3` clause.
- `enabled?/0` rescues and catches `:exit`, returning `false`. Every settings reader has the same shape with its own default, plus an `n > 0` guard on the numeric ones: a stored `"0"` in `comments_max_depth` or `comments_max_length` would otherwise reject every comment.
- Activity logging goes through `PhoenixKitComments.Activity.log_comment/3`, a pipe-step on `{:ok, %Comment{}}` (errors pass through unlogged). Actions: `comments.comment_created`, `_updated`, `_deleted`, `_approved`, `_restored`, `_hidden`. Thread the actor as `actor_uuid:` in `opts`; pass `log: false` from a wrapper mutation so one act is one line. Metadata carries status, resource type/uuid, depth, is_reply. Never a comment body, never an email. `Activity.log/2` is core's `PhoenixKit.Activity.log/3` under the `"comments"` key, which never crashes the caller (a missing table, a dead pool or an ownership error comes back as a logged `{:error, _}`).
- Soft-delete sentinel: `status: "deleted"`. `approve_comment/2` refuses a deleted row with `{:error, :comment_deleted}` (approve never means undelete; `restore_comment/2` is the undelete and picks `pending` or `published` from the moderation setting). `bulk_approve/2` counts deleted rows as failures. `get_comment_tree/2` loads `published` + `deleted` and drops deleted leaves with no children.
- Server-only attrs on `create_comment/4`: `:status` (overrides the moderation default), `:inserted_at` (backdate; not in the changeset cast), `:allow_empty_content`, `:attribution`, `:attachment_file_uuids`. Set them from your own code, never from client params. `:depth` is always recomputed from the parent.
- Attribution columns (`author_display_name`, `attribution_mode`, `attributed_project_uuid`, `attributed_label`) are outside `cast/3` and set only by `Comment.put_attribution/2` from server-computed values. Project voice never changes `user_uuid`: the public sees the project, the row keeps the accountable author.
- Metadata: `"giphy"` is reserved for the picker; keys listed in `decoration_keys` are dropped from client `metadata[...]` inputs (a client may not claim the link to one of the host's records; make it server-side in your own `create_comment/4` call). `merge_metadata/3` refuses an empty match rather than rewriting a whole resource type.
- Reads are gated, not only writes: both admin LiveViews check their key in `mount/3` (and again on every event) and redirect to `/admin` otherwise — the moderation page `PhoenixKitComments.can_moderate?/1`, the settings page `can_change_settings?/1`. Core's admin pipeline only ensures "is an admin" and the tab's `permission:` is not enforcement to rely on, so without the mount check an admin lacking the key would read every comment body, commenter email and the Giphy key.
- The moderation page shows and acts only on `moderation_scope/1`: `:all` for `comments.moderate_all`, otherwise a rule built from each handler's `moderatable_resources/2`. Every list, count, stat and type-filter query takes the rule as SQL; every event that takes a uuid (view, approve, hide, delete, restore, the bulk forms) re-reads the row through a rule computed fresh (`get_comment_for_moderation/3`, `moderation:` on the bulk functions), so an out-of-scope uuid answers exactly like a missing one. A reply's parent snippet shows only when the parent passes the rule; authors' emails only when the rule is `:all`. No own-comments exception.
- The rule binds each type's uuid list as ONE array parameter (`field in ^list` compiles to `= ANY($n)`). Never expand it into a per-uuid `IN`/`OR` chain: a handler may answer more than Postgres's 65,535-parameter limit (`moderation_permissions_test.exs` binds 70,000).
- Sub-key checks go through `Scope.can?/2`, never raw `cached_permissions` membership (Owner and `"*"` only work through the Scope functions). The exception is `can_change_settings?/1`, which uses `has_module_access?/2` on the base and the sub-key: `can?/2` also requires the module enabled, and the settings page holds the on/off switch.
- Component authorisation: edit and delete (and decoration edits, which follow edit) — the author, or a viewer who moderates the record by the moderation page's rule (`PhoenixKitComments.may_moderate_resource?/3`: `comments.moderate_all`, or the base key plus the handler's `moderatable_resources/2`), never the role alone. The event re-asks the handler against a scope current at that moment — the host's `pk_scope` when it passes one (it must send the current one with each update), otherwise one built from the database for that event, never the copy cached for rendering; the render path uses the per-update `viewer_moderates?` assign. The moderation page decides email visibility from the live `:phoenix_kit_current_scope` on every render, because core swaps the scope in place when grants change. Settings are re-read on every `update/2` (not `assign_new`), so an admin toggle takes effect without a remount; the host's attr still wins as an off switch.
- Giphy: `search_giphy/2` is gated by `giphy_enabled?/0` (toggle AND key), not by the key alone. On an exception log only the struct name; the key rides in the query string.
- Reaction dedup is a `FOR UPDATE` lock on the parent comment plus `reaction_exists?/3`, then a counter bump in the same transaction. There is no composite unique index on `(comment_uuid, user_uuid)` in core's tables, so `on_conflict` upserts raise; do not reintroduce them.
- Resource handlers dispatch by `function_exported?/3` from `PhoenixKit.ResourceLinks.handlers/0`, wrapped in rescue and `catch :exit`. Log the exit shape via `exit_summary/1`, never the reason verbatim (a `GenServer.call` reason carries the whole comment).
- Live updates: topic `phoenix_kit_comments:<resource_type>:<resource_uuid>` on the host PubSub via `PhoenixKit.PubSubHelper`; broadcasts are best-effort and never fail the write. Payload is the same `{:comments_updated, %{resource_type, resource_uuid, action}}` the component sends its parent, so one `handle_info` clause covers both.
- Rich-text composer: Leaf reports content to the HOST LiveView as `{:leaf_changed, …}`. Hard-dep hosts `use PhoenixKitComments.Embed` (an `on_mount` `:handle_info` hook that halts only editor ids prefixed `pk-comments:` and passes everything else); soft-dep hosts call `CommentsComponent.forward_leaf_event/2` at runtime via `apply/3` and treat `:pass` as "not ours" (core does this in `PhoenixKitWeb.CommentsForwarding`). Without either, Post silently posts nothing. `forward_leaf_event/2` is therefore a host contract: keep its name, arity and `{:noreply, socket} | :pass` return.
- Call `precheck_create/5` before `consume_uploaded_entries/3` so a depth/length/cap failure does not leak files into storage. Comment insert and attachment rows run in one transaction.
- The `:phoenix_kit` requirement keeps the compound `>= 2.38.0 and < 3.0.0` form — patch-precise floor, open ceiling (a three-segment `~> 2.38.x` locks out every later core minor for consumers); `core_pin_conformance_test.exs` enforces it and rejects a committed `path:` override.
- UUIDv7 primary keys everywhere; every table-backed schema has `use PhoenixKit.SchemaPrefix` right after `use Ecto.Schema` (`schema_prefix_conformance_test.exs`).
- `file_references/0` (`PhoenixKitComments.FileReferences`) declares every column of this module's tables that names a stored file (today `phoenix_kit_comment_media.file_uuid`) to core's orphan-file check. Core 3.0's built-in list no longer covers these tables, so a missing entry lists live attachments as orphans and "Delete all orphaned" trashes them. A new file column goes into that list in the same change; `file_references_test.exs` (unit: from the schemas; integration: from the foreign keys and core's own finder) fails otherwise.
- `css_sources/0` returns `[:phoenix_kit_comments]` (an atom list) so core adds the `@source` for this module's templates.
- Content ceiling: the changeset allows 100_000 characters, matching the maximum the settings page lets `comments_max_length` be clamped to. Keep the two in step.

### Landmines

- Leaf editor hangs on its loading text with no server error or log line: the host has not registered Leaf's hooks in its `LiveSocket`. Fix: wire `window.LeafHooks`, or set `comments_rich_text` to `false` / pass `rich_text={false}`.
- `assert_activity_logged` passes against code that logs nothing under a non-shared sandbox: the LiveView is another process, so its insert fails with `DBConnection.OwnershipError`, which core's `Activity.log/3` returns rather than raises. `LiveCase` tests stay `async: false`.
- `FunctionClauseError` in `Scope.user_uuid/1` from a LiveView test: the scope's user was a plain map. Use `fake_scope/1` (`cached_roles` is a list of role NAMES, `cached_permissions` a `MapSet`).
- "cannot invoke handle_params nor navigate/patch" from a filter or search event in tests: `push_patch` prepends whatever prefix `Routes.path/1` resolves. The test router mounts both `/en/admin/...` and `/phoenix_kit/en/admin/...`; keep both.
- Integration tests excluded with an "author_display_name does not exist" notice: the core in `deps/` predates the attribution columns, not a broken suite. Run against a newer core (`PHOENIX_KIT_PATH`) or update the pin.

## Architecture

`lib/phoenix_kit_comments.ex` holds the module callbacks and context API.
Under `lib/phoenix_kit_comments/`, `schemas/` holds Ecto schemas and `web/`
holds `comments_component`, moderation `index`, `settings` and the sanitised
MDEx renderer `markdown.ex`. Supporting modules include `Activity`, `Embed`,
`FileReferences`, `Gettext`, `Migrations` and `ResourceHandler`.
See the README and module docs for feature and API reference.

### Data model

- `Comment` maps to `phoenix_kit_comments`: `resource_type` max 50, user FK, self-referencing `parent_uuid` (nil at top level), zero-based depth, JSONB metadata, attribution, reaction counters, children and position-ordered media.
- `CommentLike` / `CommentDislike` map to `phoenix_kit_comments_likes` / `phoenix_kit_comments_dislikes`; their changesets name unique indexes the baseline does not create (see reaction dedup above).
- `CommentMedia` maps to `phoenix_kit_comment_media`, linking stored files. Unique `(comment_uuid, position)` index: `phoenix_kit_comment_media_comment_position_index`; comment FK cascades on physical deletion, file FK restricts deletion. Storage GC reaps unreferenced files.
- Status strings: `"published"` (default), `"pending"` (moderation on), `"hidden"`, `"deleted"`. Build trees in memory (`build_comment_tree/1`), never nested queries. Blank content requires Giphy or media (`has_media: true` on insert).

### Host contracts

Resource handlers, one per `resource_type`, read from core's `PhoenixKit.ResourceLinks.handlers/0`. A module author declares one with `resource_links/0` on their `PhoenixKit.Module` (`%{"post" => MyModule}`, no host configuration); host config (`config :phoenix_kit, :comment_resource_handlers, %{"post" => MyApp.Posts}`) is the override and wins per type, over module entries and core's built-ins. A link resolves per type through the handler's `resolve_comment_resources/1`, then a `resource_links/0` path-template entry (a link only — a template is not a handler and gets no events), then the Settings → Comments → Resource Paths template. Adopt `@behaviour PhoenixKitComments.ResourceHandler` so a misnamed callback is a compile warning instead of silence. Every callback is optional.

| Callback | Fires |
|---|---|
| `resolve_comment_resources([uuid])` | Admin display: `%{uuid => %{title, path, full_title?, thumb_url?}}`, path RAW |
| `moderatable_resources(type, scope)` | Moderation page, for a base-key holder without `comments.moderate_all`: `:all` or the resource uuids (strings) of this type the viewer may moderate comments on. Missing, `[]`, malformed, a raise or an exit all mean none (fail closed). Asked per type on every list build and every action; start from what the viewer can reach, never from every commented record |
| `on_comment_created(type, uuid, comment)` | After insert (reply: `comment.parent_uuid`) |
| `on_comment_published(type, uuid, comment)` | A `pending` comment approved (`approve_comment/2`, `bulk_approve/2`): its readers see it only now |
| `on_comment_deleted(type, uuid, comment)` | After soft delete |
| `on_comment_liked / unliked / disliked / undisliked(type, uuid, %{comment, liker_uuid})` | Only on an actual state change, never on an `:already_*` no-op |

Attachment folder hook (`PhoenixKitComments.Attachments`): `config :phoenix_kit_comments, :attachments_parent_folder, {mod, fun}` (note the app is `:phoenix_kit_comments`, not `:phoenix_kit`), called ONCE per comment as `fun(:comment_attachment, actor_uuid, %{resource_type, resource_uuid})` (or the 2-arity `fun(:comment_attachment, actor_uuid)`) and answering `{:ok, folder_uuid}` or anything else for "media root". Placement goes through core's `ResourceFolders.attach/2`: a homeless file is adopted, a file homed elsewhere (a checksum dedupe of the user's earlier upload) gets a `FolderLink`, never a move; a dedupe that lands on a file the uploader had trashed is restored and attached in one transaction (`ResourceFolders.place_stored/2`), falling back to a live file at the media root when the answered folder is gone. The hook and the placement never raise or exit into the component: they run inside `consume_uploaded_entries/3`, where a crash loses a comment whose files are already stored. Non-uuid answers are dropped before any query.

`CommentsComponent` attrs: required `id`, `resource_type`, `resource_uuid`, `current_user`; optional `enabled`, `show_likes`, `title`, `rich_text`, `show_title`, `collapsible`, `initial_collapsed`, `composer_position` (`:top` | `:bottom`), `mentions_on`, `withhold_mention_titles`, `pk_scope`, `project_attribution` (`%{project_uuid, label, verify, default_on}`), `comment_decorations`, `decoration_keys`, `parent_module`/`parent_id` (decoration `send_update` target), `editor_mode`. Slot `:form_extras` injects inputs named `metadata[<key>]`. Parent message after create/edit/delete: `{:comments_updated, %{resource_type, resource_uuid, action}}`; the same message with `action: :reaction` arrives via `PhoenixKitComments.subscribe/2`. A host showing a count or preview reloads on ANY action.

### Settings keys

README → Settings lists common keys. Other defaults: `comments_giphy_enabled`
and `comments_attachments_enabled` are false, `comments_giphy_api_key` is `""`,
and `comments_giphy_rating` is `"g"` (allowed: g/pg/pg-13/r). Keep limits aligned:

- `comments_max_depth` defaults to 10; `validate_depth/1` rejects `>= max`, allowing depths 0–9.
- `comments_max_length` defaults to 10,000; settings clamp to 100–100_000, matching the changeset ceiling.
- `comments_max_attachments` defaults to 4, range 1–10. `comments_attachment_max_size_mb` defaults to 20 and is clamped by global `storage_max_upload_size_mb`.

Resource path templates (`comment_resource_paths`, core setting managed from the settings page): `%{"shoes" => "/order/shoes/:uuid"}` or `%{"shoes" => %{"path" => …, "title" => ":metadata.name"}}`.

### Permissions and PubSub

- Permission keys (`permission_metadata/0`):
  - `comments` — the moderation page, limited to comments on records the viewer manages (`moderatable_resources/2`); author names, not emails.
  - `comments.moderate_all` — every comment on the site, with authors' emails.
  - `comments.settings` — the settings page (on/off switch, moderation, limits, Giphy key, resource paths), its sidebar entry and the moderation page's Settings shortcut.
- `migrate_legacy/0` grants both sub-keys ONCE to every role holding `comments` when it runs, through `Permissions.grant_permission/3`, one flag per sub-key (`comments_moderate_all_backfilled`, `comments_settings_backfilled`) set only after every grant succeeded; roles are listed with a query that raises (core's `roles_with_permission/1` answers `[]` on failure, which would set the flag for good). A role granted `comments` later gets the narrow meaning.
- PubSub topic `phoenix_kit_comments:<resource_type>:<resource_uuid>` (`topic/2`, `subscribe/2`, `unsubscribe/2`), resolved through `PhoenixKit.PubSubHelper` (`config :phoenix_kit, pubsub: MyApp.PubSub`).

## Database & migrations

Owns a versioned chain: `PhoenixKitComments.Migrations` via `migration_module/0`, marker `pkcmt_schema:<N>` as a `COMMENT ON TABLE` on `phoenix_kit_comments` (none reads as 0), currently **V1**. The SQL is data (`up_statements/2`, `down_statements/2`); `up/1` / `down/1` `execute/1` it, so they only work inside an `Ecto.Migration` run. `mix phoenix_kit.update` runs core's chain, then a generated wrapper calling `up(prefix:, version:)`.

- **V1 adopts the four tables core's chain creates** (`phoenix_kit_comments`, `phoenix_kit_comments_likes`, `phoenix_kit_comments_dislikes`, `phoenix_kit_comment_media`): their shape as a fresh core install builds it today (V135, V164's `fk_comments_user_uuid` delete action, V166's attribution columns, index and CHECK), with core's exact names, as `CREATE TABLE IF NOT EXISTS`, guarded `DO $$` constraint blocks and `CREATE INDEX IF NOT EXISTS`. On existing installs only the marker is new; where core no longer creates the tables, the same statements create them.
- **A change to these tables is a new version here, never a core migration** — core refuses one since V223 (its `PhoenixKit.Migrations.ModuleOwnedTables`; plan: core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's `ExpectedSchema` hands the tables over, a version that reshapes an object the manifest declares must take it out of the manifest first, or `mix phoenix_kit.repair` restores the old shape; one that only adds objects the manifest never names needs no core step.
- **Never edit a shipped version's statements**: append behind `target >= N` in `up_statements/2` and bump `@current_version`.
- **`down/1` never drops a table** — it only rewrites or clears the marker; `migrations_test.exs` asserts no emitted statement matches `DROP|TRUNCATE|DELETE`.
- **Proof the chain stands alone:** `test/integration/migrations_build_alone_test.exs` runs core's `PhoenixKit.TestSupport.ModuleChainCheck` (core after 2.64.1), which builds the tables both ways in a scratch schema and compares them. `migrations_test.exs` pins every table, index and constraint name, each FK's delete action, prefix threading, and checks the statements against core's manifest.

UUIDv7 primary keys (`uuid_generate_v7()`, never `gen_random_uuid()`); `use PhoenixKit.SchemaPrefix` on every table-backed schema.

## Testing

- Test DB `phoenix_kit_comments_test` (suffix `MIX_TEST_PARTITION`; `PGDATABASE` overrides the name). Env honoured: `PGUSER` (default `postgres`), `PGPASSWORD`, `PGHOST`, `PGDATABASE`, `PGPOOL` (pool size, default `schedulers_online() * 2`).
- Without Postgres: behaviour, schema, changeset, markdown, `Embed`, resource-handler and conformance tests run; everything under `test/integration/` is tagged `:integration` via the case templates and is excluded automatically.
- `test_helper.exs` starts the repo, PubSub and endpoint, probes the DB and attribution column, and applies core/module migrations before enabling the manual sandbox.
- Use `DataCase` fixtures (`user_fixture/1`, `comment_fixture/2`); registration's rate-limiter ETS is not started. `LiveCase` provides `fake_scope/1` and `put_test_scope/2`. Component notices use `[data-notice=<place>]`, not layout flashes. `Test.HostLive` at `/en/test/thread/:resource_uuid` has `#first-thread`; `?second_thread=<uuid>` adds `#second-thread`. Support code lives in `test/support/`.
- `config :phoenix_kit, repo: Test.Repo` is required; without it every context call falls into its own rescue and returns a plausible nothing.
- Known noise: the "Integration tests excluded" banner when the DB is missing or the core in `deps/` lacks the attribution columns; a "redefining module PhoenixKitComments.Test.Repo" warning (support files are both compiled from `test/support` and `Code.require_file`d by the helper); `count_comments/3 failed, reporting 0` ownership warnings from the unit tests that assert the rescue path on purpose.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`).
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- Likes/dislikes have no database-level uniqueness on `(comment_uuid, user_uuid)`. Adding the index is now a version of this module's chain (de-duplicating existing rows first); its names must match the changesets' `unique_constraint` names (`uq_comments_likes_comment_user`, `uq_comments_dislikes_comment_user`), and the lock + precheck can then become an `on_conflict` insert.
