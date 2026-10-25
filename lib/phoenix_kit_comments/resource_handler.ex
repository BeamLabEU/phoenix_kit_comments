defmodule PhoenixKitComments.ResourceHandler do
  @moduledoc """
  The contract a module implements to hook into comments.

  One handler per `resource_type`. A PhoenixKit module names its own from
  `resource_links/0`, which needs no host configuration:

      def resource_links, do: %{"post" => MyModule.Posts}

  A host overrides that, or registers a type no PhoenixKit module owns, in
  config — the config entry wins for its type:

      config :phoenix_kit, :comment_resource_handlers, %{
        "post" => MyApp.Posts
      }

  Both land in core's `PhoenixKit.ResourceLinks.handlers/0`, the one registry
  this package dispatches from. A `resource_links/0` entry that is a path
  template rather than a module makes the record clickable but is not a
  handler: it receives no events.

  Every callback is optional — implement only the events you care about — so
  a handler is free to be a two-line module that reacts to one thing.

  ## Why adopt the behaviour

  Dispatch is by `function_exported?/3`, and it always will be: a handler is
  named by a module or in host config, may live in another application, and
  may legitimately implement none of these. That is a good property, and it
  has one bad consequence — a callback this package never finds is indistinguishable from
  one you chose not to write. Misname `on_comment_create` (no `d`), take two
  arguments instead of three, and nothing happens: no error, no warning, no
  notification, and nothing to grep for. The host discovers it when someone
  reports that notifications stopped.

  `@behaviour PhoenixKitComments.ResourceHandler` turns that into a compile
  warning at the point of the mistake. It is not required and changes nothing
  at runtime; it only makes the failure loud. Handlers registered today keep
  working untouched.

      defmodule MyApp.Posts do
        @behaviour PhoenixKitComments.ResourceHandler

        @impl true
        def on_comment_created(_type, post_uuid, comment) do
          MyApp.Posts.notify_author(post_uuid, comment)
        end
      end

  ## What is passed

  The event callbacks all receive the `resource_type` and `resource_uuid` the
  comment was filed against, so one handler can serve several types.

  Reaction callbacks take a map rather than the comment alone because the
  comment row carries its *author*, not the person reacting — `:liker_uuid`
  is the only place that appears.

  ## Paths are RAW

  `resolve_comment_resources/1` returns `path` WITHOUT the PhoenixKit url
  prefix — the renderer applies `Routes.path/1` once. A handler that
  pre-prefixes gets a doubled prefix.

  ## What is NOT decided here

  Reaction callbacks fire only when the state actually changed
  (`{:ok, :liked}`), never on an `:already_liked` no-op. Self-action skipping
  — not notifying someone who liked their own comment — is left to the
  handler, which is the only party that knows whether that matters.

  A callback that raises is caught and logged; it cannot fail the comment
  that triggered it.
  """

  alias PhoenixKitComments.Comment

  @typedoc "The host's own type key for a commentable record, e.g. `\"order\"`."
  @type resource_type :: String.t()

  @typedoc "The record's uuid."
  @type resource_uuid :: Ecto.UUID.t()

  @typedoc """
  A reaction event. The comment plus who reacted — the row itself only knows
  its author.
  """
  @type reaction :: %{comment: Comment.t(), liker_uuid: Ecto.UUID.t()}

  @doc """
  Titles and RAW deep-links for the given uuids.

  Returns `%{uuid => %{title: String.t(), path: String.t()}}`. May also
  carry `:full_title` (tooltip) and `:thumb_url` (chip thumbnail); a uuid
  the handler does not recognise is simply absent from the map.
  """
  @callback resolve_comment_resources([resource_uuid()]) :: %{
              optional(resource_uuid()) => map()
            }

  @doc "A comment was created. Check `comment.parent_uuid` to tell a reply apart."
  @callback on_comment_created(resource_type(), resource_uuid(), Comment.t()) :: any()

  @doc """
  A comment held for moderation was approved, so its readers can now see it.
  Fires once, when a `pending` comment becomes `published` (`approve_comment/2`,
  `bulk_approve/2`); a comment published on creation fires
  `on_comment_created/3` with status `"published"` instead, so a handler that
  tells people about a comment reacts to both.
  """
  @callback on_comment_published(resource_type(), resource_uuid(), Comment.t()) :: any()

  @doc "A comment was soft-deleted."
  @callback on_comment_deleted(resource_type(), resource_uuid(), Comment.t()) :: any()

  @doc "Someone liked a comment. Fires only on an actual change of state."
  @callback on_comment_liked(resource_type(), resource_uuid(), reaction()) :: any()

  @doc "Someone withdrew a like."
  @callback on_comment_unliked(resource_type(), resource_uuid(), reaction()) :: any()

  @doc "Someone disliked a comment."
  @callback on_comment_disliked(resource_type(), resource_uuid(), reaction()) :: any()

  @doc "Someone withdrew a dislike."
  @callback on_comment_undisliked(resource_type(), resource_uuid(), reaction()) :: any()

  @optional_callbacks resolve_comment_resources: 1,
                      on_comment_created: 3,
                      on_comment_published: 3,
                      on_comment_deleted: 3,
                      on_comment_liked: 3,
                      on_comment_unliked: 3,
                      on_comment_disliked: 3,
                      on_comment_undisliked: 3

  @doc """
  The callbacks this package dispatches, as `{name, arity}`.

  Exposed so the dispatcher and the contract can be checked against each
  other — a callback added to one and not the other is exactly the silent
  mismatch this module exists to prevent.
  """
  @spec callbacks() :: [{atom(), arity()}]
  def callbacks, do: __MODULE__.behaviour_info(:callbacks) |> Enum.sort()

  @doc """
  The comment-event callbacks, i.e. everything except
  `resolve_comment_resources/1`.

  These are the ones the dispatcher fires by name with three arguments;
  `resolve_comment_resources/1` is a lookup the renderer calls directly and
  answers a different question, so checks over "the events" have to exclude
  it rather than assume the contract is uniform.
  """
  @spec event_callbacks() :: [{atom(), arity()}]
  def event_callbacks,
    do: Enum.filter(callbacks(), fn {name, _} -> name != :resolve_comment_resources end)
end
