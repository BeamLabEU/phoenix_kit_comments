# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit Comments module — provides resource-agnostic, polymorphic commenting with unlimited nested threading, like/dislike reactions, moderation, and an admin dashboard. Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

## Common Commands

```bash
mix deps.get          # Install dependencies
mix test              # Run all tests
mix test test/phoenix_kit_comments_test.exs  # Run specific test file
mix test --only tag   # Run tests matching a tag
mix format            # Format code
mix credo             # Static analysis / linting
mix dialyzer          # Type checking
mix docs              # Generate documentation
```

## Architecture

This is a **library** (not a standalone Phoenix app) that provides commenting as a PhoenixKit plugin module.

### File Layout

```
lib/
  phoenix_kit_comments/
    phoenix_kit_comments.ex          # Main module — context + PhoenixKit.Module behaviour
    schemas/
      comment.ex                     # Polymorphic comment schema with self-referencing threads
      comment_like.ex                # Like tracking (one per user per comment)
      comment_dislike.ex             # Dislike tracking (one per user per comment)
    web/
      comments_component.ex          # Reusable LiveComponent for embedding on any page
      index.ex                       # Admin moderation dashboard LiveView
      settings.ex                    # Admin settings LiveView
```

### Key Modules

- **`PhoenixKitComments`** (`lib/phoenix_kit_comments/phoenix_kit_comments.ex`) — Main module implementing `PhoenixKit.Module` behaviour AND serving as the context module for all comment operations (CRUD, threading, likes/dislikes, moderation, resource handler callbacks).

- **`PhoenixKitComments.Comment`** (`lib/phoenix_kit_comments/schemas/comment.ex`) — Ecto schema for polymorphic comments with self-referencing threading via `parent_uuid`. Fields: `resource_type`, `resource_uuid`, `user_uuid`, `content`, `status`, `depth`, `like_count`, `dislike_count`, `metadata`.

- **`PhoenixKitComments.CommentLike`** (`lib/phoenix_kit_comments/schemas/comment_like.ex`) — Like tracking schema with unique constraint on `(comment_uuid, user_uuid)`.

- **`PhoenixKitComments.CommentDislike`** (`lib/phoenix_kit_comments/schemas/comment_dislike.ex`) — Dislike tracking schema with unique constraint on `(comment_uuid, user_uuid)`.

- **`PhoenixKitComments.Web.CommentsComponent`** (`lib/phoenix_kit_comments/web/comments_component.ex`) — LiveComponent for embedding comments on any page. Accepts `resource_type`, `resource_uuid`, `current_user`. Handles comment creation, replies, deletion, and recursive tree rendering.

- **`PhoenixKitComments.Web.Index`** (`lib/phoenix_kit_comments/web/index.ex`) — Admin moderation dashboard with search, filtering (status, resource_type), pagination, and bulk actions.

- **`PhoenixKitComments.Web.Settings`** (`lib/phoenix_kit_comments/web/settings.ex`) — Admin settings page for module configuration.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers the moderation dashboard; PhoenixKit generates routes at compile time
4. `settings_tabs/0` registers the settings page under admin settings
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Polymorphic Resource Design

Comments attach to **any** resource via a `(resource_type, resource_uuid)` tuple — no foreign keys on the resource side. This means any module (posts, entities, tickets, etc.) can use comments without schema coupling.

Resource modules can register callbacks to hook into the comment lifecycle:

```elixir
# In parent app config
config :phoenix_kit, :comment_resource_handlers, %{
  "post" => PhoenixKitPosts,
  "entity" => PhoenixKitEntities
}
```

Handler modules may implement:
- `on_comment_created/3` — called after comment creation
- `on_comment_deleted/3` — called after deletion
- `resolve_comment_resources/1` — returns `%{uuid => %{title: ..., path: ...}}` for admin display

### Comment Threading

- **Self-referencing** via `parent_uuid` (nil = top-level comment)
- **Depth tracking** auto-calculated from parent: 0 = top-level, 1 = reply, 2+ = nested reply
- **Tree building** done in-memory via `build_comment_tree/1` (recursive, not nested DB queries)
- **Soft delete** via status field (`"deleted"`), not database row removal

### Comment Status

Four statuses as strings:
- `"published"` — visible to all (default for new comments, or when moderation is off)
- `"pending"` — awaiting moderation (when `comments_moderation` is enabled)
- `"hidden"` — hidden by moderator
- `"deleted"` — soft-deleted

### Like/Dislike Counters

- **Denormalized** on Comment schema (`like_count`, `dislike_count`)
- **Transaction-safe** increment/decrement operations
- **One-per-user** enforced by unique constraints

### Database Tables

- `phoenix_kit_comments` — Comment records (UUIDv7 PK, self-referencing `parent_uuid`)
- `phoenix_kit_comments_likes` — Like records with unique `(comment_uuid, user_uuid)` constraint (`uq_comments_likes_comment_user`)
- `phoenix_kit_comments_dislikes` — Dislike records with unique `(comment_uuid, user_uuid)` constraint (`uq_comments_dislikes_comment_user`)

### Settings Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `comments_enabled` | boolean | false | Module on/off |
| `comments_moderation` | boolean | false | New comments start as "pending" |
| `comments_max_depth` | integer | 10 | Maximum nesting level |
| `comments_max_length` | integer | 10000 | Maximum comment character length |

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"comments"`
- **Tab IDs**: prefixed with `:admin_comments` (main tab) and `:admin_settings_comments` (settings tab)
- **URL paths**: `/admin/comments` (moderation dashboard), `/admin/settings/comments` (settings)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **LiveViews use `PhoenixKitWeb` macros** — use `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView` directly)
- **JavaScript hooks**: must be inline `<script>` tags; register on `window.PhoenixKitHooks`
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **UUIDv7 primary keys** — all tables use `uuid_generate_v7()`, never `gen_random_uuid()`
- **Admin routing** — plugin LiveView routes are auto-discovered by PhoenixKit and compiled into `live_session :phoenix_kit_admin`. Never hand-register them in a parent app's `router.ex`; use `live_view:` on a tab or a route module. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `["phoenix_kit_comments"]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Versioning & Releases

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-24" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_comments/phoenix_kit_comments.ex` (`version/0`), and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

Review template should use severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `NITPICK`, `OBSERVATION`. Include a "What Was Done Well" section. Use `-- FIXED` notation for resolved issues.

## External Dependencies

- **PhoenixKit** (path: `"../phoenix_kit"`) — Module behaviour, Settings API, shared components, RepoHelper, Utils (Date, UUID, Routes), Users.Auth.User, Users.Roles
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews and CommentsComponent
- **ex_doc** (`~> 0.34`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis
- **dialyxir** (`~> 1.4`, dev/test) — Type checking
