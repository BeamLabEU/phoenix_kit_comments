# PhoenixKitComments

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.15-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Resource-agnostic, polymorphic commenting module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). Drop-in comments with unlimited nested threading, like/dislike reactions, moderation, and an admin dashboard.

## Features

- **Polymorphic comments** — attach comments to any resource via `(resource_type, resource_uuid)` with zero schema coupling
- **Unlimited nested threading** — self-referencing `parent_uuid` with automatic depth tracking
- **Like/dislike reactions** — one per user per comment, with denormalized counters and transaction-safe updates
- **Moderation** — optional approval workflow; comments start as `"pending"` when moderation is enabled
- **Admin dashboard** — search, filter by status/resource type, paginate, and perform bulk actions
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config
- **LiveView component** — embeddable `CommentsComponent` for any page

## Installation

Add `phoenix_kit_comments` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_comments, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_comments, github: "mdon/phoenix_kit_comments"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`comments_enabled: true`)
4. Embed the `CommentsComponent` in your LiveViews

## Usage

### Embedding comments on a page

Use the `CommentsComponent` LiveComponent in any LiveView:

```heex
<.live_component
  module={PhoenixKitComments.Web.CommentsComponent}
  id="comments"
  resource_type="post"
  resource_uuid={@post.uuid}
  current_user={@current_user}
/>
```

### Resource handler callbacks

Modules that consume comments can register handlers to receive lifecycle notifications:

```elixir
# config/config.exs
config :phoenix_kit, :comment_resource_handlers, %{
  "post" => PhoenixKitPosts,
  "entity" => PhoenixKitEntities
}
```

Handler modules can implement:

- `on_comment_created/3` — called after a comment is created
- `on_comment_deleted/3` — called after a comment is deleted
- `resolve_comment_resources/1` — returns `%{uuid => %{title: ..., path: ...}}` for admin display

### Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `comments_enabled` | boolean | `false` | Enable/disable the module |
| `comments_moderation` | boolean | `false` | Require approval for new comments |
| `comments_max_depth` | integer | `10` | Maximum thread nesting level |
| `comments_max_length` | integer | `10000` | Maximum comment length (characters) |

### Moderation Workflow

When `comments_moderation` is enabled:
- New comments start with status `"pending"`
- Admins can approve (set to `"published"`) or reject (set to `"hidden"`)
- Approved comments become visible to all users
- Rejected comments remain hidden but are not deleted

### Permissions

The module declares permissions via `permission_metadata/0`:
- `:admin_comments` — Access to moderation dashboard
- `:admin_settings_comments` — Access to settings page

Use `Scope.has_module_access?/2` to check permissions in your application.

### CSS Requirements

For Tailwind CSS users: ensure `phoenix_kit_comments` is listed in your `tailwind.config.js` sources:

```javascript
module.exports = {
  content: [
    // ...
    "./deps/phoenix_kit_comments/**/*.{heex,ex}",
    // ...
  ]
}
```

## Architecture

```
lib/
  phoenix_kit_comments.ex              # Context + PhoenixKit.Module behaviour
  phoenix_kit_comments/
    schemas/
      comment.ex                       # Polymorphic comment schema with threading
      comment_like.ex                  # Like tracking (unique per user per comment)
      comment_dislike.ex               # Dislike tracking (unique per user per comment)
    web/
      comments_component.ex            # Embeddable LiveComponent
      index.ex                         # Admin moderation dashboard
      settings.ex                      # Admin settings page
```

### Comment statuses

| Status | Description |
|--------|-------------|
| `"published"` | Visible to all (default when moderation is off) |
| `"pending"` | Awaiting moderator approval |
| `"hidden"` | Hidden by a moderator |
| `"deleted"` | Soft-deleted |

### Database tables

- `phoenix_kit_comments` — comment records (UUIDv7 primary keys)
- `phoenix_kit_comments_likes` — like records with unique `(comment_uuid, user_uuid)` constraint
- `phoenix_kit_comments_dislikes` — dislike records with unique `(comment_uuid, user_uuid)` constraint

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo          # Static analysis
mix dialyzer       # Type checking
mix docs           # Generate documentation
```

## Troubleshooting

### Comments not appearing
- Verify `comments_enabled` is `true` in settings
- Check that the resource type matches exactly (case-sensitive)
- Ensure the current user is authenticated and passed to the component

### CSS classes missing
- Add `phoenix_kit_comments` to your Tailwind content sources
- Run `mix assets.deploy` to rebuild CSS

### Permission denied errors
- Verify the user has the `:admin_comments` permission
- Check that `Scope.has_module_access?/2` returns `true`

## License

MIT — see [LICENSE](LICENSE) for details.
