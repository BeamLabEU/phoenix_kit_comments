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
    {:phoenix_kit_comments, "~> 0.3"}
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

### Attachment folder

Uploaded attachments land at the media root by default. To keep them next to the
commented record instead, point a hook at the folder:

```elixir
config :phoenix_kit_comments, :attachments_parent_folder, {MyApp.Media, :parent_for}

# in MyApp.Media
def parent_for(:comment_attachment, _actor_uuid, %{resource_type: "order", resource_uuid: uuid}),
  do: {:ok, order_folder_uuid(uuid)}

def parent_for(_kind, _actor_uuid, _subject), do: nil
```

It is called once per comment. Anything other than `{:ok, folder_uuid}` leaves the
files at the root, and a hook that raises or exits never fails the comment.

### Live updates across sessions

`CommentsComponent` keeps the **posting** user's own view fresh automatically.
To also update *other* connected users (e.g. a comment-count badge or an open
thread on another screen) when anyone comments, edits, deletes, or reacts, subscribe
the host LiveView to the resource's comment activity:

```elixir
def mount(_params, _session, socket) do
  # Subscribe in the connected branch only — mount runs twice.
  if connected?(socket) do
    PhoenixKitComments.subscribe("order", order_uuid)
  end

  {:ok, socket}
end

# Fired for create / edit / delete / reaction across every session viewing the resource.
def handle_info({:comments_updated, %{resource_type: _, resource_uuid: _, action: action}}, socket) do
  # action is :created | :updated | :deleted | :reaction
  {:noreply, refresh_comment_counts(socket)}
end
```

The broadcast payload mirrors the `{:comments_updated, …}` message the component
already sends to its own host, so you have one message contract for both local
and remote updates. The PubSub server is resolved via `PhoenixKit.PubSubHelper`
(configure with `config :phoenix_kit, pubsub: MyApp.PubSub`).

### Counting comments for many resources at once

When rendering a list of commentable resources (e.g. one count badge per row),
pass a **list** of UUIDs to `count_comments/3` to get a `uuid => count` map in a
single grouped query instead of N separate counts:

```elixir
# One query; every requested uuid is present, missing ones as 0.
PhoenixKitComments.count_comments("order", [uuid_a, uuid_b, uuid_c])
#=> %{uuid_a => 3, uuid_b => 0, uuid_c => 7}
```

It honors the same `:status` / `:include_deleted` options as the scalar form.

### Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `comments_enabled` | boolean | `false` | Enable/disable the module |
| `comments_moderation` | boolean | `false` | Require approval for new comments |
| `comments_rich_text` | boolean | `true` | Use the Leaf rich-text editor in the composer (see [JavaScript wiring](#javascript-wiring)) |
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
- `"comments"` — Access to moderation dashboard
- `"comments"` — Access to settings page

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

### Embedding the composer (required for rich text)

The comment composer's rich-text editor lives in a separate LiveComponent, and
its `{:leaf_changed, _}` messages arrive at the HOST LiveView. Without
forwarding them the composer looks fine and "Post comment" silently posts
nothing.

```elixir
defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view
  use PhoenixKitComments.Embed        # attaches the forwarding hook
end
```

`Embed` uses a lifecycle hook rather than injecting a `handle_info/2` clause,
so it composes with a host that already has its own.

⚠️ **If you write your own `handle_info/2`, give it a catch-all.** The
component also sends `{:comments_updated, _}` to the host on create, edit,
and delete. LiveView only tolerates unmatched messages when a view exports NO
`handle_info/2` — the moment you define one clause, an unmatched message
raises `FunctionClauseError` and kills the LiveView.

```elixir
def handle_info({:comments_updated, _payload}, socket), do: {:noreply, socket}
def handle_info(_msg, socket), do: {:noreply, socket}
```

## Resource handler callbacks

Implement `PhoenixKitComments.ResourceHandler` to hook into comments on your
records. Every callback is optional:

| Callback | Fires when |
|---|---|
| `resolve_comment_resources/1` | the admin list needs titles + links for your records |
| `on_comment_created/3` | a comment lands on one of your records |
| `on_comment_deleted/3` | a comment is soft-deleted |
| `on_comment_liked/3` · `on_comment_unliked/3` | reaction added / removed |
| `on_comment_disliked/3` · `on_comment_undisliked/3` | reaction added / removed |

`resolve_comment_resources/1` returns `%{uuid => %{title:, path:}}` and may add
`:full_title` and `:thumb_url`. **`path` is RAW** — the renderer applies the
PhoenixKit url prefix once, so a pre-prefixed path is doubled.

## JavaScript wiring

The comment composer's optional features rely on JS hooks that **the host
application must register** in its `LiveSocket`. If a hook isn't registered, the
feature that uses it won't work — most notably the **Leaf rich-text editor will
hang on its loading text with no server-side error or log line**.

In your `app.js`:

```js
// Leaf rich-text editor (used by the comment composer when comments_rich_text is on)
import "../../deps/leaf/priv/static/assets/leaf.js"

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    ...(window.LeafHooks || {}),
    // ...your other hooks
  },
})
```

If you don't want rich text — or can't wire the JS — set `comments_rich_text` to
`false` in settings, or pass `rich_text={false}` to the component. The composer
then falls back to a plain `<textarea>`, which needs no JS and always works:

```heex
<.live_component
  module={PhoenixKitComments.Web.CommentsComponent}
  id="comments"
  resource_type="post"
  resource_uuid={@post.uuid}
  current_user={@current_user}
  rich_text={false}
/>
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

### Comment editor stuck on a loading word ("Polishing…", etc.)
- The Leaf rich-text editor's JS hook isn't registered in your `LiveSocket`.
  See [JavaScript wiring](#javascript-wiring) — import Leaf's JS and spread
  `window.LeafHooks` into your hooks.
- Or disable rich text: set `comments_rich_text` to `false`, or pass
  `rich_text={false}` to the component to use the plain-textarea fallback.

### Permission denied errors
- Verify the user has the `"comments"` permission
- Check that `Scope.has_module_access?/2` returns `true`

## License

MIT — see [LICENSE](LICENSE) for details.
