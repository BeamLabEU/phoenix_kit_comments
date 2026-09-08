# AGENTS.md

Guidance for AI agents working on `phoenix_kit_comments`.

## Overview

Resource-agnostic, polymorphic commenting for PhoenixKit hosts: unlimited nested
threading, like/dislike reactions, Giphy and file attachments, in-browser voice
notes, markdown bodies, moderation, activity logging and live (PubSub) updates.
A comment attaches to any record through a `(resource_type, resource_uuid)` pair
with no foreign key on the resource side. `PhoenixKitComments` is both the
`PhoenixKit.Module` implementation and the context module (CRUD, threading,
reactions, moderation, handler dispatch); `Web.CommentsComponent` is the
embeddable LiveComponent; two admin LiveViews cover moderation and settings.
It is a library, not an application: it borrows the host's endpoint, router,
repo and PubSub.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_live_view` `~> 1.1`, `giphy_api` `~> 0.1.1`. MDEx is used directly but NOT declared: core provides it transitively so every module shares one resolved version; never add a direct `mdex` dep. No sibling module deps. Newer core seams (`PhoenixKit.Mentions`, `PhoenixKit.Activity`, `PhoenixKit.Settings.get_editor_mode/0`) are probed with `Code.ensure_loaded?/1` and degrade to off.
- **Consumed by:** `phoenix_kit_crm`, `phoenix_kit_posts`, `phoenix_kit_staff`, `phoenix_kit_projects`, `phoenix_kit_catalogue` (supplier comments), `phoenix_kit_publishing` (test-only dep). Core's `MediaCanvasViewer` embeds the component for annotation threads.
- **Admin surface:** tab `:admin_comments` at `/admin/comments` (moderation dashboard; group `:admin_modules`, `match: :prefix`); settings subtab `:admin_settings_comments` at `/admin/settings/comments` (parent `:admin_settings`). Both carry `permission: "comments"`.
- **Module key** `"comments"`; settings prefix `comments_`.

## What this module does NOT do

- Owns no migrations. All four tables ship in core's chain; `migration_module/0` is unset.
- Never references the commented resource's table. Linking is by `(resource_type, resource_uuid)` only, so any module can comment on anything without schema coupling.
- Does not resolve resource titles or links itself. `resolve_resource_context/1` and the path templates delegate to core's `PhoenixKit.ResourceLinks`, the same resolver the Activity feed uses; the `comment_resource_paths` setting is core's.
- Does not hard-delete. `delete_comment/2` sets `status: "deleted"`; media rows cascade only if the row is ever physically removed.
- Does not decide self-action skipping for reaction callbacks (whether to notify someone who liked their own comment). The handler decides.
- Does not authorise host records through metadata. The component authorises the comment (own or admin); a decoration edit hands `actor_uuid` to the host, which owns the record and must decide.
- Ships no Leaf editor JS and no mention hook. Leaf's bundle and core's `MentionInput` are registered by the host; this module falls back to a plain `<textarea>` when Leaf is off.
- Depends on no sibling module. Posts, staff, projects and the rest depend on comments, never the reverse.

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

## Conventions

- Module key `"comments"` in every callback; tab ids `:admin_comments` and `:admin_settings_comments`; URL segment `comments` on both tabs; setting keys prefixed `comments_`.
- Paths go through `PhoenixKit.Utils.Routes.path/1`, never hardcoded or relative. A handler's `resolve_comment_resources/1` returns RAW paths without the URL prefix; the renderer applies `Routes.path/1` once, so a pre-prefixed path doubles.
- Routing: `live_view:` on both tabs; no `route_module/0`. Core compiles the routes into `live_session :phoenix_kit_admin`; never hand-register them in a host router. Reference: core's `guides/custom-admin-pages.md`.
- LiveView macros: `use PhoenixKitWeb, :live_view` (Index, Settings) and `use PhoenixKitWeb, :live_component` (CommentsComponent), each immediately followed by `use Gettext, backend: PhoenixKitComments.Gettext`. The order matters: the second `use` rebinds the `gettext` macros from core's backend to this module's. Templates never wrap in `LayoutWrapper`; `Web.Markdown` is a plain `Phoenix.Component`.
- Gettext: own backend `PhoenixKitComments.Gettext`, catalogs in `priv/gettext` (`en`, `et`, `ru`, domain `default`). `mix gettext.extract --merge` regenerates them. A new locale is named by the dialect core resolves to (`de-DE`, not `de`; `ru` and `et` map to themselves). Tab labels are plain strings translated by core through the Tab's `gettext_backend:`/`gettext_domain:`, so a label's msgid must exist in the catalog: anchor it with a `gettext("…")` call somewhere in `lib/` or it never enters the pot.
- JS hooks ship as the prebuilt bundle `priv/static/assets/phoenix_kit_comments.js`, folded into the host `LiveSocket` by core from `js_sources/0` under the global `PhoenixKitCommentsHooks`. Never register a hook from an inline `<script>`: a hook has to be in the LiveSocket when it is constructed, and morphdom does not execute inserted script tags, so an inline hook vanishes on LiveView navigation (`unknown hook found for "…"`). Hook names are namespaced (`PhoenixKitCommentsAudioRecorder`, `PhoenixKitCommentsInsertAtCursor`) because the fold into `window.PhoenixKitHooks` is last-write-wins across every module's bundle and core's own hooks.
- `enabled?/0` rescues and catches `:exit`, returning `false`. Every settings reader has the same shape with its own default, plus an `n > 0` guard on the numeric ones: a stored `"0"` in `comments_max_depth` or `comments_max_length` would otherwise reject every comment.
- Activity logging goes through `PhoenixKitComments.Activity.log_comment/3`, a pipe-step on `{:ok, %Comment{}}` (errors pass through unlogged). Actions: `comments.comment_created`, `_updated`, `_deleted`, `_approved`, `_restored`, `_hidden`. Thread the actor as `actor_uuid:` in `opts`; pass `log: false` from a wrapper mutation so one act is one line. Metadata carries status, resource type/uuid, depth, is_reply. Never a comment body, never an email. Logging never crashes the caller (missing table, dead pool, ownership error are all `:ok`).
- Soft-delete sentinel: `status: "deleted"`. `approve_comment/2` refuses a deleted row with `{:error, :comment_deleted}` (approve never means undelete; `restore_comment/2` is the undelete and picks `pending` or `published` from the moderation setting). `bulk_approve/2` counts deleted rows as failures. `get_comment_tree/2` loads `published` + `deleted` and drops deleted leaves with no children.
- Server-only attrs on `create_comment/4`: `:status` (overrides the moderation default), `:inserted_at` (backdate; not in the changeset cast), `:allow_empty_content`, `:attribution`, `:attachment_file_uuids`. Set them from your own code, never from client params. `:depth` is always recomputed from the parent.
- Attribution columns (`author_display_name`, `attribution_mode`, `attributed_project_uuid`, `attributed_label`) are outside `cast/3` and set only by `Comment.put_attribution/2` from server-computed values. Project voice never changes `user_uuid`: the public sees the project, the row keeps the accountable author.
- Metadata: `"giphy"` is reserved for the picker; keys listed in `decoration_keys` are dropped from client `metadata[...]` inputs (a client may not claim the link to one of the host's records; make it server-side in your own `create_comment/4` call). `merge_metadata/3` refuses an empty match rather than rewriting a whole resource type.
- Reads are gated, not only writes: both admin LiveViews check `Scope.has_module_access?(scope, "comments")` in `mount/3` (and again on every mutation) and redirect to `/admin` otherwise. Core's admin pipeline only ensures "is an admin"; the tab's `permission:` only controls sidebar visibility, so without the mount check an admin lacking the comments permission would read every comment body, commenter email and the Giphy key.
- Component edit/delete authorisation: the comment's author or a user with the Owner/Admin role. Settings are re-read on every `update/2` (not `assign_new`), so an admin toggle takes effect without a remount; the host's attr still wins as an off switch.
- Giphy: `search_giphy/2` is gated by `giphy_enabled?/0` (toggle AND key), not by the key alone. On an exception log only the struct name; the key rides in the query string.
- Reaction dedup is a `FOR UPDATE` lock on the parent comment plus `reaction_exists?/3`, then a counter bump in the same transaction. There is no composite unique index on `(comment_uuid, user_uuid)` in core's tables, so `on_conflict` upserts raise; do not reintroduce them.
- Resource handlers dispatch by `function_exported?/3` from `PhoenixKit.ResourceLinks.handlers/0`, wrapped in rescue and `catch :exit`. Log the exit shape via `exit_summary/1`, never the reason verbatim (a `GenServer.call` reason carries the whole comment).
- Live updates: topic `phoenix_kit_comments:<resource_type>:<resource_uuid>` on the host PubSub via `PhoenixKit.PubSubHelper`; broadcasts are best-effort and never fail the write. Payload is the same `{:comments_updated, %{resource_type, resource_uuid, action}}` the component sends its parent, so one `handle_info` clause covers both.
- Rich-text composer: Leaf reports content to the HOST LiveView as `{:leaf_changed, …}`. Hard-dep hosts `use PhoenixKitComments.Embed` (an `on_mount` `:handle_info` hook that halts only editor ids prefixed `pk-comments:` and passes everything else); soft-dep hosts call `CommentsComponent.forward_leaf_event/2` at runtime via `apply/3` and treat `:pass` as "not ours" (core does this in `PhoenixKitWeb.CommentsForwarding`). Without either, Post silently posts nothing. `forward_leaf_event/2` is therefore a host contract: keep its name, arity and `{:noreply, socket} | :pass` return.
- Call `precheck_create/5` before `consume_uploaded_entries/3` so a depth/length/cap failure does not leak files into storage. Comment insert and attachment rows run in one transaction.
- The `:phoenix_kit` requirement stays a two-segment `~> 2.0` (a three-segment `~> 2.0.x` locks out every later core minor for consumers); `core_pin_conformance_test.exs` enforces it and rejects a committed `path:` override.
- UUIDv7 primary keys everywhere; every table-backed schema has `use PhoenixKit.SchemaPrefix` right after `use Ecto.Schema` (`schema_prefix_conformance_test.exs`).
- `css_sources/0` returns `[:phoenix_kit_comments]` (an atom list) so core adds the `@source` for this module's templates.
- Content ceiling: the changeset allows 100_000 characters, matching the maximum the settings page lets `comments_max_length` be clamped to. Keep the two in step.

### Landmines

- Leaf editor hangs on its loading text with no server error or log line: the host has not registered Leaf's hooks in its `LiveSocket`. Fix: wire `window.LeafHooks`, or set `comments_rich_text` to `false` / pass `rich_text={false}`.
- `assert_activity_logged` passes against code that logs nothing under a non-shared sandbox: `Activity.log/2` rescues `DBConnection.OwnershipError` to `:ok` and the LiveView is another process. `LiveCase` tests stay `async: false`.
- `FunctionClauseError` in `Scope.user_uuid/1` from a LiveView test: the scope's user was a plain map. Use `fake_scope/1` (`cached_roles` is a list of role NAMES, `cached_permissions` a `MapSet`).
- "cannot invoke handle_params nor navigate/patch" from a filter or search event in tests: `push_patch` prepends whatever prefix `Routes.path/1` resolves. The test router mounts both `/en/admin/...` and `/phoenix_kit/en/admin/...`; keep both.
- Integration tests excluded with an "author_display_name does not exist" notice: the core in `deps/` predates the attribution columns, not a broken suite. Run against a newer core (`PHOENIX_KIT_PATH`) or update the pin. On the Mac the test role defaults to `postgres`; use `PGUSER=maxdon`.

## Architecture

```
lib/
  phoenix_kit_comments.ex            # PhoenixKit.Module callbacks + the whole context API
  phoenix_kit_comments/
    activity.ex                      # Activity-log wrapper (log/2, log_comment/3)
    embed.ex                         # `use PhoenixKitComments.Embed`: Leaf forwarding hook for hosts
    gettext.ex                       # Own Gettext backend (priv/gettext)
    resource_handler.ex              # @behaviour for host handlers; callbacks/0, event_callbacks/0
    schemas/
      comment.ex                     # phoenix_kit_comments; threading, attribution, content-or-media rule
      comment_like.ex                # phoenix_kit_comments_likes
      comment_dislike.ex             # phoenix_kit_comments_dislikes
      comment_media.ex               # phoenix_kit_comment_media (junction to Storage files)
    web/
      comments_component.ex(.heex)   # Embeddable LiveComponent: composer, tree, reactions, uploads, mentions
      index.ex(.heex)                # Admin moderation dashboard
      settings.ex(.heex)             # Admin settings page (+ resource path templates)
      markdown.ex                    # comment_markdown/1 via MDEx (sanitised allow-list)
priv/static/assets/phoenix_kit_comments.js   # Hook bundle (js_sources/0)
priv/gettext/                        # default.pot, en, et, ru
```

### Data model

| Table | Schema | Notes |
|---|---|---|
| `phoenix_kit_comments` | `Comment` | `resource_type` (max 50), `resource_uuid`, `user_uuid` → users, `parent_uuid` → self (nil = top level), `content`, `status`, `depth` (0-based), `like_count`, `dislike_count`, `metadata` JSONB, attribution columns. `has_many :children`, `has_many :media` (ordered by position). |
| `phoenix_kit_comments_likes` | `CommentLike` | `(comment_uuid, user_uuid)`; dedup is app-side (lock + precheck), the changeset's `unique_constraint` names an index the baseline does not create. |
| `phoenix_kit_comments_dislikes` | `CommentDislike` | Same shape and rule as likes. |
| `phoenix_kit_comment_media` | `CommentMedia` | Junction to `phoenix_kit_files`; unique `(comment_uuid, position)` (`phoenix_kit_comment_media_comment_position_index`); `ON DELETE CASCADE` on `comment_uuid`, `ON DELETE RESTRICT` on `file_uuid` (the file is reaped by storage GC when no junction row references it). |

Statuses (strings): `"published"` (default; visible), `"pending"` (moderation on: new comments start here), `"hidden"` (moderator), `"deleted"` (soft delete). Tree building is in memory (`build_comment_tree/1`), never nested queries. Counters are denormalized on the comment and bumped inside the reaction transaction. Blank content is allowed only with a Giphy entry or media (`has_media: true` on insert); admins can raise the ceiling but the changeset caps content at 100_000.

### Host contracts

Resource handlers, registered per `resource_type` in host config (`config :phoenix_kit, :comment_resource_handlers, %{"post" => MyApp.Posts}`); adopt `@behaviour PhoenixKitComments.ResourceHandler` so a misnamed callback is a compile warning instead of silence. Every callback is optional.

| Callback | Fires |
|---|---|
| `resolve_comment_resources([uuid])` | Admin display: `%{uuid => %{title, path, full_title?, thumb_url?}}`, path RAW |
| `on_comment_created(type, uuid, comment)` | After insert (reply: `comment.parent_uuid`) |
| `on_comment_deleted(type, uuid, comment)` | After soft delete |
| `on_comment_liked / unliked / disliked / undisliked(type, uuid, %{comment, liker_uuid})` | Only on an actual state change, never on an `:already_*` no-op |

`CommentsComponent` attrs: required `id`, `resource_type`, `resource_uuid`, `current_user`; optional `enabled`, `show_likes`, `title`, `rich_text`, `show_title`, `collapsible`, `initial_collapsed`, `composer_position` (`:top` | `:bottom`), `mentions_on`, `withhold_mention_titles`, `pk_scope`, `project_attribution` (`%{project_uuid, label, verify, default_on}`), `comment_decorations`, `decoration_keys`, `parent_module`/`parent_id` (decoration `send_update` target), `editor_mode`. Slot `:form_extras` injects inputs named `metadata[<key>]`. Parent message after create/edit/delete: `{:comments_updated, %{resource_type, resource_uuid, action}}`; the same message with `action: :reaction` arrives via `PhoenixKitComments.subscribe/2`. A host showing a count or preview reloads on ANY action.

### Settings keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `comments_enabled` | boolean | false | Module on/off |
| `comments_moderation` | boolean | false | New comments start as `"pending"` |
| `comments_max_depth` | integer | 10 | Nesting limit. Depths are 0-based and `validate_depth/1` rejects at `>= max`, so 10 yields depths 0–9 |
| `comments_max_length` | integer | 10000 | Maximum comment length; settings page clamps to 100–100_000 |
| `comments_giphy_enabled` | boolean | false | Show the Giphy picker |
| `comments_giphy_api_key` | string | "" | Giphy API key (DB-stored) |
| `comments_giphy_rating` | string | "g" | Giphy rating filter (g/pg/pg-13/r) |
| `comments_attachments_enabled` | boolean | false | Image/video/audio/file attachments and voice recording |
| `comments_max_attachments` | integer | 4 | Per-comment attachment cap (1–10) |
| `comments_attachment_max_size_mb` | integer | 20 | Per-file cap (MB), clamped by the global `storage_max_upload_size_mb` |
| `comments_rich_text` | boolean | true | Leaf composer + markdown rendering (`comment_markdown/1`) |

Resource path templates (`comment_resource_paths`, core setting managed from the settings page): `%{"shoes" => "/order/shoes/:uuid"}` or `%{"shoes" => %{"path" => …, "title" => ":metadata.name"}}`.

### Permissions and PubSub

- Permission key `"comments"` (`permission_metadata/0`); gates both admin pages and the sidebar entries. No sub-permissions.
- PubSub topic `phoenix_kit_comments:<resource_type>:<resource_uuid>` (`topic/2`, `subscribe/2`, `unsubscribe/2`), resolved through `PhoenixKit.PubSubHelper` (`config :phoenix_kit, pubsub: MyApp.PubSub`).

## Database & migrations

None. Tables `phoenix_kit_comments`, `phoenix_kit_comments_likes`, `phoenix_kit_comments_dislikes` and `phoenix_kit_comment_media` ship in core's chain (V135 baseline; the attribution columns arrive later in the same chain); `migration_module/0` is unset. A schema change is a core migration first, then schema edits here. UUIDv7 primary keys (`uuid_generate_v7()`, never `gen_random_uuid()`); `use PhoenixKit.SchemaPrefix` on every table-backed schema.

## Testing

- Test DB `phoenix_kit_comments_test` (suffix `MIX_TEST_PARTITION`; `PGDATABASE` overrides the name). Env honoured: `PGUSER` (default `postgres`), `PGPASSWORD`, `PGHOST`, `PGDATABASE`, `PGPOOL` (pool size, default `schedulers_online() * 2`).
- Without Postgres: behaviour, schema, changeset, markdown, `Embed`, resource-handler and conformance tests run; everything under `test/integration/` is tagged `:integration` via the case templates and is excluded automatically.
- `test_helper.exs` starts `Test.Repo` and a `PhoenixKit.PubSub` server, runs `TestRepo.query!("SELECT 1")` first (the repo connects lazily), builds the schema with `PhoenixKit.Migration.ensure_current/2` (no module-owned DDL), probes for the attribution column before switching the sandbox to `:manual`, then starts `Test.Endpoint`.
- Support modules: `DataCase` (sandbox owner, `user_fixture/1` inserted directly because the registration rate limiter's ETS is not started, `comment_fixture/2`), `LiveCase` (`Test.Endpoint`, `Phoenix.LiveViewTest`, `fake_scope/1`, `put_test_scope/2`), `Test.Router` (both admin prefixes, the `/en/test/thread/:resource_uuid` host page, a `StubController` at `/admin` so refused redirects are assertable), `Test.Hooks` (`:assign_scope` on_mount replicating core's admin `live_session` assigns), `Test.Layouts` (flashes with stable ids), `Test.HostLive` (embeds the component the way a consumer does; `decoration_keys` from the URL), `ActivityLogAssertions` (`assert_activity_logged/2`).
- `config :phoenix_kit, repo: Test.Repo` is required; without it every context call falls into its own rescue and returns a plausible nothing.
- Known noise: the "Integration tests excluded" banner when the DB is missing or the core in `deps/` lacks the attribution columns; a "redefining module PhoenixKitComments.Test.Repo" warning (support files are both compiled from `test/support` and `Code.require_file`d by the helper); `count_comments/3 failed, reporting 0` ownership warnings from the unit tests that assert the rescue path on purpose.

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s (`PhoenixKitComments`, `ResourceHandler`, `Embed`, `Web.CommentsComponent`) and the README.

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

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- The `:phoenix_kit` floor (`~> 2.0`) admits cores without the attribution columns, and `test_helper.exs` still probes for them. Raise the floor to the first core release carrying that migration once every consumer runs on it; until then keep `display_name/1` guarded at its call site.
- Likes/dislikes have no database-level uniqueness on `(comment_uuid, user_uuid)`; when core adds the index, the changesets' `unique_constraint` names (`uq_comments_likes_comment_user`, `uq_comments_dislikes_comment_user`) must match it, and the lock + precheck can become an `on_conflict` insert.
