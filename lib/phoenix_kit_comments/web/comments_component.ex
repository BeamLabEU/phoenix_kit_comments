defmodule PhoenixKitComments.Web.CommentsComponent do
  @moduledoc """
  Reusable LiveComponent for displaying and managing comments on any resource.

  ## Usage

      <.live_component
        module={PhoenixKitComments.Web.CommentsComponent}
        id={"comments-\#{@post.uuid}"}
        resource_type="post"
        resource_uuid={@post.uuid}
        current_user={@current_user}
      />

  ## Required Attrs

  - `resource_type` - String identifying the resource type (e.g., "post")
  - `resource_uuid` - UUID of the resource
  - `current_user` - Current authenticated user struct
  - `id` - Unique component ID

  ## Optional Attrs

  - `enabled` - Whether comments are enabled (default: true)
  - `show_likes` - Show like/dislike buttons (default: true)
  - `title` - Section title (default: "Comments")
  - `rich_text` - Use the rich-text (Leaf) editor in the composer
    (default: the `comments_rich_text` setting, which defaults to `true`).
    Pass `false` to force the plain `<textarea>` — useful when the host
    hasn't registered Leaf's JS hook, since the Leaf editor otherwise hangs
    on its loading text with no server-side error. See the README's
    "JavaScript wiring" section.

  ## Slots

  - `:form_extras` - Custom markup rendered inside the new-comment form. Use it to
    inject parent-project inputs whose names are `metadata[<key>]`; their values are
    merged into `comment.metadata` on submit. The `"giphy"` key is reserved for the
    built-in Giphy picker, and any key listed in `decoration_keys` is dropped —
    a client may not claim the link between a comment and one of your records.
    Make that link server-side, in your own `create_comment/4` call.

        <:form_extras>
          <input type="color" name="metadata[box_color]" value="#ff5555" />
        </:form_extras>

  ## Parent Notifications

  After create/edit/delete, sends to the parent LiveView:

      {:comments_updated, %{resource_type: "post", resource_uuid: uuid, action: :created | :updated | :deleted}}

  The same message (plus `action: :reaction`) arrives over PubSub for
  changes made elsewhere — `PhoenixKitComments.subscribe/2` — so one
  `handle_info` clause covers both. A host rendering a preview or count of
  the resource's comments should reload on ANY action rather than matching
  a subset.
  """

  use PhoenixKitWeb, :live_component
  # Rebind gettext macros to the comments module's own catalogs (priv/gettext).
  use Gettext, backend: PhoenixKitComments.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitComments.Web.Markdown, only: [comment_markdown: 1, comment_markdown_styles: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  require Logger

  @bytes_per_mb 1024 * 1024
  alias PhoenixKit.Users.Roles

  # Leaf is an optional dep. When present, the comment form swaps
  # textareas for `<.live_component module={Leaf}>`. Without leaf
  # installed, the form falls back to plain textareas with no
  # behavior change. `@compile {:no_warn_undefined, [Leaf]}` keeps
  # dialyzer / compiler quiet in the leaf-absent build; runtime
  # behavior is guarded by `leaf_available?/0`.
  @compile {:no_warn_undefined, [Leaf]}

  # `get_editor_mode/0` only exists in newer phoenix_kit builds, but our
  # pin still allows older ones — `default_editor_mode/0` probes for it at
  # runtime, so the compiler shouldn't flag the call in the meantime.
  @compile {:no_warn_undefined, {PhoenixKit.Settings, :get_editor_mode, 0}}

  # The modes Leaf's `:mode` attr accepts, and the one Leaf itself
  # defaults to. Anything outside this list must never reach Leaf —
  # its mode clauses have no catch-all.
  @leaf_editor_modes [:visual, :hybrid, :markdown, :html]
  @default_editor_mode :hybrid

  @impl true
  def mount(socket) do
    max_size_mb = PhoenixKitComments.get_max_attachment_size_mb()
    max_entries = PhoenixKitComments.get_max_attachments()

    {:ok,
     socket
     |> assign(:comments, [])
     |> assign(:comment_count, 0)
     |> assign(:loaded?, false)
     |> assign(:reply_to, nil)
     # nil | :top | :bottom — which placement (see composer_position)
     # currently has the open compose form. At most one is open at a
     # time so the Leaf editor id + the single :attachment upload input
     # never render twice.
     |> assign(:composer_open_at, nil)
     |> assign(:new_comment, "")
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")
     # Per-decoration inline-edit state. The uuid is a
     # `{metadata_key, comment_uuid}` tuple (or nil) so two different
     # decoration kinds on the same comment don't collide.
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")
     |> assign(:giphy_open?, false)
     |> assign(:giphy_query, "")
     |> assign(:giphy_results, [])
     |> assign(:giphy_selected, nil)
     |> assign(:giphy_searching?, false)
     |> assign(:attach_menu_open?, false)
     |> assign(:recording_audio?, false)
     |> assign(:liked_comment_uuids, MapSet.new())
     |> assign(:disliked_comment_uuids, MapSet.new())
     |> assign(:expanded_comments, MapSet.new())
     |> assign(:max_attachments, max_entries)
     |> assign(:max_attachment_size_mb, max_size_mb)
     |> allow_upload(:attachment,
       accept: ~w(
         image/*
         video/*
         audio/*
         .pdf .doc .docx .txt .md
       ),
       max_entries: max_entries,
       max_file_size: max_size_mb * @bytes_per_mb
     )}
  end

  # Leaf content forwarded from a host LV via `forward_leaf_event/2`.
  # `:draft` updates the new-comment / reply assign; `:edit` updates
  # the inline-edit assign. Either way the next form submit reads
  # from socket.assigns instead of params (Leaf doesn't bubble
  # form-collectable elements to the parent form).
  @impl true
  def update(%{leaf_content_changed: %{kind: kind, content: content}}, socket)
      when kind in [:draft, :reply] do
    {:ok, assign(socket, :new_comment, content)}
  end

  def update(%{leaf_content_changed: %{kind: :edit, content: content}}, socket) do
    {:ok, assign(socket, :editing_content, content)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      # Defaults to the MODULE's own switch, not to `true`. An admin turning
      # comments off in settings expects that to reach embedded threads; with
      # a hardcoded default it only reached the admin pages, and every host
      # that embedded this component without passing `enabled=` kept taking
      # writes. A host attr still wins, as an additional off switch.
      #
      # Re-read on EVERY update rather than `assign_new`, like the three
      # settings reads below it: `assign_new` samples the setting once and
      # the `@write_events` gate then consults that frozen copy forever, so
      # a thread that was open when the admin flipped the switch went on
      # accepting writes until its next full mount — which is precisely the
      # case the gate exists for. A host's own `enabled=` is remembered
      # separately so a partial `send_update` that omits it cannot
      # accidentally re-enable a thread the host turned off.
      |> then(&assign(&1, :host_enabled, Map.get(assigns, :enabled, &1.assigns[:host_enabled])))
      |> then(&assign(&1, :enabled, effective_enabled(&1.assigns.host_enabled)))
      |> assign_new(:show_likes, fn -> true end)
      |> assign_new(:title, fn -> gettext("Comments") end)
      # Rich-text (Leaf) editor opt-out. Host attr wins; otherwise the
      # `comments_rich_text` setting (default true). The effective
      # `:leaf_editor?` below also requires Leaf to actually be loaded.
      |> assign_new(:rich_text, fn -> PhoenixKitComments.rich_text_enabled?() end)
      # PUBLIC surfaces set this. A comment body goes through the same
      # mention resolver as everything else, and with the site-wide
      # redaction setting off (its sensible default) that resolver looks up
      # the CURRENT title of records the reader cannot open. On a page
      # anyone can read, a hand-typed `#[project_task:...]` therefore
      # published an internal name — the typeahead never offers one, but
      # nothing stops someone typing it, and nothing validates tokens on
      # write.
      |> assign_new(:withhold_mention_titles, fn -> false end)
      # Set by hosts that can vouch for a project voice. A map of
      # %{project_uuid, label, verify: (user_uuid -> boolean), default_on}.
      # nil — the default — means the control never renders and nobody can
      # claim to speak for anything.
      |> assign_new(:project_attribution, fn -> nil end)
      # The @/# typeahead, on the PLAIN textarea only: the rich editor owns
      # its own key handling, and a second listener fighting it for the
      # caret is how you get a composer that eats keystrokes.
      |> assign_new(:mentions_on, fn -> mentions_available?() end)
      # Built ONCE per render, not per comment: resolving a mention needs a
      # scope (permissions, not just a uuid), and Scope.for_user/1 reads the
      # database — doing it inside the comment loop would be one query per
      # comment on every page.
      |> assign_new(:pk_scope, fn -> nil end)
      # Header presentation. `show_title` renders the
      # "{title} ({count})" line; `collapsible` turns that line into a
      # disclosure toggle for the whole body; `initial_collapsed` is the
      # starting state (ephemeral — see :collapsed? seed below). All
      # default to today's behavior (title shown, not collapsible,
      # expanded).
      |> assign_new(:show_title, fn -> true end)
      |> assign_new(:collapsible, fn -> false end)
      |> assign_new(:initial_collapsed, fn -> false end)
      # Where the "Write comment" composer renders: :top (default),
      # :bottom, or :both. Bottom is off by default.
      |> assign_new(:composer_position, fn -> :top end)
      |> assign_new(:form_extras, fn -> [] end)
      |> assign_new(:current_user, fn -> nil end)
      # Same reason as :pk_scope above — `user_is_admin?/1` is two `exists?`
      # queries, and the render path asks it four times per comment,
      # recursively per reply, so a long thread was hundreds of role queries
      # per re-render. Reads the SOCKET, not the incoming assigns, because a
      # send_update may omit `:current_user`.
      #
      # Once per UPDATE, not once per component: `assign_new` here would
      # freeze the viewer's role for the component's whole life, so a host
      # that mounts with `current_user: nil` and sends the loaded user after
      # (the async-load pattern) would render every comment for a stranger,
      # and a role revoked mid-session would keep its Edit/Delete controls.
      # The event handlers re-check for real, so this is what the viewer
      # SEES, not what they may do — but it should still be current.
      |> then(&assign(&1, :viewer_is_admin?, user_is_admin?(&1.assigns[:current_user])))
      # Optional per-comment decoration registry. Generic surface
      # for rendering an external label above the comment body,
      # driven by one of the comment's `metadata[key]` fields. The
      # comments package stays domain-agnostic; the caller declares
      # which metadata field to read and what label to display for
      # each known value.
      #
      # Shape:
      #
      #     %{
      #       <metadata_key> => %{
      #         <metadata_value> => %{
      #           label: <string>,           # required — what to render
      #           on_save: <atom> | nil      # optional — fires send_update
      #                                      # to parent_module/parent_id
      #                                      # when set; nil = read-only
      #         },
      #         ...
      #       },
      #       ...
      #     }
      #
      # Example consumers:
      #   PhoenixKit's MediaCanvasViewer for annotation titles:
      #     %{"annotation_uuid" => %{
      #         "abc-uuid" => %{label: "Sky shot", on_save: :annotation_title_updated}
      #       }}
      #   Hypothetical post-category decoration:
      #     %{"category_id" => %{
      #         "42" => %{label: "Releases", on_save: nil}
      #       }}
      #
      # The first matching decoration wins per comment; multiple
      # decorations per comment aren't supported in this iteration.
      |> assign_new(:comment_decorations, fn -> %{} end)
      # The metadata KEYS this host decorates with, as a static list —
      # `["annotation_uuid"]` for the viewer above. Separate from the
      # registry because the registry is built from data and is empty
      # before there is anything to label, while the set of keys a client
      # must never write is fixed. See `decoration_keys/1`.
      |> assign_new(:decoration_keys, fn -> [] end)
      # Parent component to receive `send_update` when a decoration
      # is inline-edited (only relevant for decorations whose
      # entry sets `on_save`). The payload shape is:
      #
      #     %{action: <on_save atom>,
      #       metadata_key: <string>,
      #       metadata_value: <string>,
      #       label: <new string>,
      #       actor_uuid: <uuid> | nil}
      #
      # `actor_uuid` is who clicked. This component authorizes the COMMENT
      # (you may edit your own), which is not the same question as "may
      # this person rename that host record" — the link between the two is
      # a metadata value, and metadata is not proof of anything. The host
      # owns the record and must decide; it is given the actor to decide
      # with.
      |> assign_new(:parent_module, fn -> nil end)
      |> assign_new(:parent_id, fn -> nil end)
      # Derive from the RESOLVED socket value (kept across updates by the
      # assign_new above), NOT the incoming `assigns`. A partial
      # `send_update` that omits `:current_user` — e.g. a parent poking
      # `loaded?: false` to refresh the thread (MediaCanvasViewer does this
      # when an annotation is drawn) — would otherwise read nil and flip
      # the composer to "Sign in to post a comment" for a logged-in user.
      |> then(&assign(&1, :can_post?, &1.assigns.current_user != nil))
      |> then(
        &assign(&1, :pk_scope, &1.assigns[:pk_scope] || viewer_scope(&1.assigns.current_user))
      )
      |> assign(:giphy_enabled?, PhoenixKitComments.giphy_enabled?())
      |> assign(:attachments_enabled?, PhoenixKitComments.attachments_enabled?())
      |> assign(:max_length, PhoenixKitComments.get_max_length())
      # Effective editor choice: rich text only when the host wants it AND
      # Leaf is loaded. All composer/edit/submit paths key off this.
      |> then(&assign(&1, :leaf_editor?, &1.assigns.rich_text and leaf_available?()))
      # Site-wide default editor mode (admin-set under Settings → Content
      # Editor); passed to every Leaf instance this component renders.
      # Seeded once: Leaf only honours `:mode` on its first render, so
      # re-reading the setting on every update/2 would cost a settings
      # lookup per parent re-render and change nothing on screen.
      |> assign_new(:editor_mode, &default_editor_mode/0)

    # Seed collapse state once from initial_collapsed, then leave it
    # alone. assign_new only fires when :collapsed? is absent, so the
    # user's toggle survives later update/2 + send_update passes
    # (ephemeral within the component's lifetime, host sets the start).
    socket = assign_new(socket, :collapsed?, fn -> socket.assigns.initial_collapsed end)

    reload? = changed?(socket, :resource_uuid) or not socket.assigns.loaded?

    socket =
      if reload? do
        socket |> load_comments() |> assign(:loaded?, true)
      else
        socket
      end

    # Reaction state depends only on the loaded comments + the viewer.
    # Re-run it when comments reload or when those inputs change, rather
    # than firing two queries on every parent re-render / send_update.
    socket =
      if reload? or changed?(socket, :current_user) or changed?(socket, :show_likes) do
        load_reaction_state(socket)
      else
        socket
      end

    {:ok, socket}
  end

  # `@enabled` used to wrap the TEMPLATE only. The component still rendered
  # its outer div, so its cid stayed live and addressable: a page already
  # open when an admin switched comments off — or a replayed push — could
  # still create, delete and react. The markup is not the control.
  #
  # Reads are left alone: hiding a thread should not make the rows
  # unreadable to code that already has them.
  #
  # `giphy_search` is in here for the second reason as much as the first: it
  # spends the HOST's Giphy quota on a client-chosen query string, so a
  # thread left open after an admin turned comments off could still bill the
  # host for searches.
  @write_events ~w(add_comment save_edit delete_comment toggle_like toggle_dislike
                   save_decoration begin_decoration_edit giphy_search)

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    # Asked NOW, not read off an assign. A `phx-submit` reaches this
    # function directly: `update/2` does not run first, so `@enabled` still
    # holds whatever the last render put there. A thread that was open when
    # an admin turned comments off therefore kept accepting writes — the
    # exact case this gate exists to close.
    #
    # Permitted writes re-enter under `{:write, event}`, which this clause
    # cannot match (the guard admits only the strings), so each handler
    # stays where it is and the gate stays the single place the question is
    # asked. LiveView only ever calls this with a binary; the tagged form is
    # internal.
    if writes_enabled?(socket) do
      handle_event({:write, event}, params, socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Comments are turned off here."))}
    end
  end

  def handle_event({:write, "add_comment"}, _params, %{assigns: %{can_post?: false}} = socket) do
    {:noreply, put_flash(socket, :error, gettext("Sign in to post a comment"))}
  end

  def handle_event({:write, "add_comment"}, params, socket) do
    # When Leaf is the editor, content lives in socket.assigns
    # (kept fresh by forwarded `:leaf_changed` messages from the
    # host LV). The form submit doesn't carry Leaf's contenteditable.
    # Falls back to params for the plain-textarea path.
    comment_text =
      params
      |> Map.get("comment")
      |> case do
        nil ->
          if socket.assigns.leaf_editor?,
            do: socket.assigns.new_comment,
            else: ""

        text ->
          text
      end

    metadata_params = client_metadata(params, socket)

    metadata =
      case socket.assigns.giphy_selected do
        nil -> metadata_params
        gif -> Map.put(metadata_params, "giphy", gif)
      end

    base_attrs = %{
      content: comment_text,
      parent_uuid: socket.assigns.reply_to,
      metadata: metadata,
      attribution: resolve_attribution(socket, params)
    }

    entries = socket.assigns.uploads.attachment.entries
    entry_count = length(entries)

    # Precheck before `consume_uploaded_entries` so depth / length /
    # cap / feature-flag failures don't burn the upload — the entries
    # stay staged and the user can fix the input and resubmit.
    # `do_create_comment/2` carries the local Leaf-draft reset and the
    # composer / attach-menu close assigns on success.
    case PhoenixKitComments.precheck_create(
           socket.assigns.resource_type,
           socket.assigns.resource_uuid,
           socket.assigns.current_user.uuid,
           base_attrs,
           entry_count
         ) do
      :ok ->
        # `consume_uploaded_entries/3` raises "cannot consume uploaded files
        # when entries are still in progress", and a LiveComponent raising
        # takes the whole host LiveView with it — composer draft, staged
        # files and any sibling state. The submit button has no disabled
        # state while a file is climbing, so this was one impatient click on
        # a slow connection.
        if uploads_done?(entries) do
          do_create_comment(socket, base_attrs)
        else
          {:noreply, put_flash(socket, :error, gettext("Wait for uploads to finish."))}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, create_error_message(reason))}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  def handle_event("audio_recording_started", _params, socket) do
    {:noreply, assign(socket, :recording_audio?, true)}
  end

  def handle_event("audio_recording_stopped", _params, socket) do
    {:noreply, assign(socket, :recording_audio?, false)}
  end

  # Mapped from a fixed set of reason codes. This used to take the client's
  # own string and put it straight into the flash — untranslated in every
  # locale, and an open invitation to paint arbitrary text in the app's own
  # error chrome ("Your session expired, sign in at …"). A non-binary value
  # also reached `put_flash/3` and raised.
  def handle_event("audio_recording_error", %{"reason" => reason}, socket)
      when is_binary(reason) do
    {:noreply,
     socket
     |> assign(:recording_audio?, false)
     |> put_flash(:error, audio_error_message(reason))}
  end

  def handle_event("audio_recording_error", _params, socket) do
    {:noreply, assign(socket, :recording_audio?, false)}
  end

  @impl true
  def handle_event("open_composer", params, socket) do
    # Position comes from phx-value-position on the button; default :top
    # so an older caller without the value still opens the top composer.
    position =
      case params["position"] do
        "bottom" -> :bottom
        _ -> :top
      end

    {:noreply, assign(socket, :composer_open_at, position)}
  end

  @impl true
  def handle_event("toggle_collapsed", _params, socket) do
    {:noreply, assign(socket, :collapsed?, not socket.assigns.collapsed?)}
  end

  # YouTube-style inline expand/collapse of a long comment body.
  def handle_event("toggle_comment_expanded", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded_comments

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded_comments, expanded)}
  end

  @impl true
  def handle_event("update_comment_draft", %{"comment" => text}, socket) when is_binary(text) do
    {:noreply, assign(socket, :new_comment, text)}
  end

  def handle_event("update_comment_draft", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_new_comment", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_comment, "")
     |> assign(:reply_to, nil)
     |> assign(:composer_open_at, nil)
     |> assign(:giphy_selected, nil)
     |> assign(:giphy_open?, false)
     |> assign(:giphy_results, [])
     |> assign(:giphy_query, "")
     |> assign(:attach_menu_open?, false)}
  end

  @impl true
  def handle_event("toggle_giphy_picker", _params, socket) do
    {:noreply, assign(socket, :giphy_open?, not socket.assigns.giphy_open?)}
  end

  @impl true
  def handle_event("close_giphy_picker", _params, socket) do
    {:noreply, assign(socket, :giphy_open?, false)}
  end

  def handle_event("toggle_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, not socket.assigns.attach_menu_open?)}
  end

  def handle_event("close_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, false)}
  end

  def handle_event("open_giphy_from_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:attach_menu_open?, false)
     |> assign(:giphy_open?, true)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Signed-in only. The picker never renders for a logged-out viewer, but the
  # markup is not the control: the component's cid is addressable by anyone
  # who can see the page, so an anonymous visitor could drive outbound calls
  # against the host's Giphy quota with query strings of their choosing. The
  # same question `add_comment` asks, asked here for the same reason.
  def handle_event({:write, "giphy_search"}, _params, %{assigns: %{can_post?: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event({:write, "giphy_search"}, %{"value" => query}, socket)
      when is_binary(query) do
    # Off the LiveView process. This called out to api.giphy.com INSIDE
    # `handle_event`, so a slow or unreachable Giphy blocked every other
    # event on the page — typing, likes, replies, navigation — for the full
    # request timeout, with the UI frozen and no indication why.
    #
    # `start_async` also gives the in-flight guard this never had: a
    # keystroke supersedes the previous search instead of stacking requests
    # against the host's quota.
    {:noreply,
     socket
     |> assign(:giphy_query, query)
     |> assign(:giphy_searching?, true)
     |> start_async(:giphy_search, fn -> PhoenixKitComments.search_giphy(query) end)}
  end

  def handle_event({:write, "giphy_search"}, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_giphy", %{"id" => gif_id}, socket) do
    case Enum.find(socket.assigns.giphy_results, &(&1["id"] == gif_id)) do
      nil ->
        {:noreply, socket}

      gif ->
        {:noreply,
         socket
         |> assign(:giphy_selected, gif)
         |> assign(:giphy_open?, false)}
    end
  end

  @impl true
  def handle_event("remove_giphy", _params, socket) do
    {:noreply, assign(socket, :giphy_selected, nil)}
  end

  def handle_event({:write, "toggle_like"}, %{"id" => comment_uuid}, socket) do
    toggle_reaction(socket, comment_uuid, :like)
  end

  def handle_event({:write, "toggle_dislike"}, %{"id" => comment_uuid}, socket) do
    toggle_reaction(socket, comment_uuid, :dislike)
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_uuid}, socket) do
    # Validated against THIS thread. The delete and edit paths already check
    # that a comment belongs to the current resource; the reply path took
    # any string. A uuid from another resource was accepted by
    # `create_comment/4` (the FK is to comments, not to the resource), and
    # `get_comment_tree/2` only walks roots of this resource — so the reply
    # was stored, published and counted, and rendered in neither thread. The
    # author saw "Comment added" and their comment nowhere. A malformed uuid
    # raised CastError on submit and killed the LiveView.
    if find_comment_in_tree(socket.assigns.comments, comment_uuid) do
      {:noreply,
       socket
       |> assign(:reply_to, comment_uuid)
       |> assign(:composer_open_at, nil)
       |> assign(:new_comment, "")
       |> assign(:editing_uuid, nil)
       |> assign(:editing_content, "")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  @impl true
  def handle_event("edit_comment", %{"id" => comment_uuid}, socket) do
    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found"))}

      comment ->
        if can_edit_comment?(socket.assigns.current_user, comment) do
          # When the comment has a matching decoration entry,
          # pre-fill `:editing_decoration_value` so the unified
          # edit form opens with the live label. No-op for comments
          # with no decoration — the input renders behind a guard.
          decoration_label =
            decoration_label_for(comment, socket.assigns.comment_decorations)

          {:noreply,
           socket
           |> assign(:editing_uuid, comment_uuid)
           |> assign(:editing_content, comment.content)
           |> assign(:editing_decoration_value, decoration_label)
           |> assign(:reply_to, nil)}
        else
          {:noreply,
           put_flash(socket, :error, gettext("You don't have permission to edit this comment"))}
        end
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_uuid, nil)
     |> assign(:editing_content, "")
     |> assign(:editing_decoration_value, "")}
  end

  def handle_event({:write, "save_edit"}, params, socket) do
    comment_uuid = socket.assigns.editing_uuid

    # Same Leaf-vs-textarea source split as `add_comment`.
    content =
      params
      |> Map.get("content")
      |> case do
        nil ->
          if socket.assigns.leaf_editor?,
            do: socket.assigns.editing_content,
            else: ""

        text when is_binary(text) ->
          text

        # `content[x]=y` arrives as a map and used to reach String.trim/1
        # in do_save_edit, killing the host LiveView. The create path was
        # hardened for exactly this payload; the edit path was not.
        _ ->
          ""
      end

    # Preload :media so `do_save_edit` can tell a genuinely-empty edit apart
    # from clearing the text of a GIF/attachment comment (which is allowed).
    case PhoenixKitComments.get_comment(comment_uuid, preload: [:media]) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found"))}

      comment ->
        save_edit_for(socket, comment, content, params)
    end
  end

  # ── Decoration inline-edit ───────────────────────────────────
  # Decorations live on the consumer's parent resource (e.g. an
  # annotation's title in PhoenixKit's MediaCanvasViewer), not on
  # the comment row. We provide UI + state plumbing; the parent
  # component owns the actual write via the configured per-entry
  # `:on_save` action atom.

  @decoration_label_max 200

  def handle_event({:write, "begin_decoration_edit"}, %{"uuid" => comment_uuid}, socket) do
    case decoration_if_permitted(comment_uuid, socket) do
      %{label: label, on_save: on_save, metadata_key: metadata_key} when not is_nil(on_save) ->
        {:noreply,
         socket
         |> assign(:editing_decoration_uuid, {metadata_key, comment_uuid})
         |> assign(:editing_decoration_value, label || "")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_decoration_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")}
  end

  def handle_event(
        {:write, "save_decoration"},
        %{"uuid" => comment_uuid, "label" => label},
        socket
      )
      when is_binary(label) do
    case decoration_if_permitted(comment_uuid, socket) do
      %{on_save: on_save, metadata_key: metadata_key, metadata_value: metadata_value}
      when not is_nil(on_save) ->
        if socket.assigns.parent_module && socket.assigns.parent_id do
          Phoenix.LiveView.send_update(socket.assigns.parent_module,
            id: socket.assigns.parent_id,
            action: on_save,
            metadata_key: metadata_key,
            metadata_value: metadata_value,
            # Capped server-side. `maxlength` on the input is a courtesy to
            # the person typing, not a limit — the event can carry anything.
            label: cap_decoration_label(label),
            actor_uuid: actor_uuid(socket)
          )
        end

      _ ->
        :ok
    end

    {:noreply,
     socket
     |> assign(:editing_decoration_uuid, nil)
     |> assign(:editing_decoration_value, "")}
  end

  # A non-binary `label` (`label[a]=b`) used to reach String.trim/1 and kill
  # the LiveView. Must sit AFTER the real clause, not before it.
  def handle_event({:write, "save_decoration"}, _params, socket), do: {:noreply, socket}

  def handle_event({:write, "delete_comment"}, %{"id" => comment_uuid}, socket) do
    case PhoenixKitComments.get_comment(comment_uuid) do
      nil ->
        {:noreply, socket |> put_flash(:error, gettext("Comment not found"))}

      comment ->
        do_delete_comment(socket, comment)
    end
  end

  # Forward a decoration label captured by the comment-edit form
  # to the parent component (only when the comment has a matching
  # decoration entry with an `:on_save` action). Called from
  # `save_edit` alongside the comment-content write so a single
  # Save click persists both surfaces in one tick.
  defp maybe_forward_decoration_update(socket, comment, params) do
    label = Map.get(params, "label")
    parent_module = socket.assigns.parent_module
    parent_id = socket.assigns.parent_id

    with true <- is_binary(label),
         true <- parent_module != nil and parent_id != nil,
         %{on_save: on_save, metadata_key: metadata_key, metadata_value: metadata_value}
         when not is_nil(on_save) <-
           find_decoration_for_comment(comment, socket.assigns.comment_decorations) do
      Phoenix.LiveView.send_update(parent_module,
        id: parent_id,
        action: on_save,
        metadata_key: metadata_key,
        metadata_value: metadata_value,
        # Same cap as the dedicated `save_decoration` path. This one forwards
        # a label captured by the comment-edit form, and it trimmed without
        # bounding — so the server-side limit the sibling declares was one
        # forged `save_edit` away from not existing.
        label: cap_decoration_label(label),
        actor_uuid: actor_uuid(socket)
      )
    end

    :ok
  end

  # nil means "the host said nothing", so the module's own switch decides —
  # re-read on every update. A host that passed `enabled=` keeps its answer.
  defp effective_enabled(nil), do: PhoenixKitComments.enabled?()
  defp effective_enabled(host_value), do: host_value

  # The same question as `:enabled`, asked at event time rather than at
  # render time. `:host_enabled` is the host's own switch, remembered across
  # partial updates; with no host answer the module setting decides, read
  # fresh.
  defp writes_enabled?(socket) do
    effective_enabled(socket.assigns[:host_enabled]) == true
  end

  defp cap_decoration_label(label) when is_binary(label) do
    label |> String.trim() |> String.slice(0, @decoration_label_max)
  end

  defp actor_uuid(socket) do
    case socket.assigns[:current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # Finds the first decoration entry that matches a comment. Scans
  # `comment_decorations` in iteration order; returns a map with
  # `:label, :on_save, :metadata_key, :metadata_value` or `nil`.
  # Multi-decoration support (rendering more than one label per
  # comment) is intentionally out of scope for now.
  defp find_decoration_for_comment(comment, decorations) when is_map(decorations) do
    metadata = comment.metadata || %{}

    Enum.find_value(decorations, fn {metadata_key, values_map} ->
      with value when is_binary(value) <- Map.get(metadata, metadata_key),
           %{} = entry <- Map.get(values_map, value) do
        entry
        |> Map.put_new(:on_save, nil)
        |> Map.merge(%{metadata_key: metadata_key, metadata_value: value})
      else
        _ -> nil
      end
    end)
  end

  defp find_decoration_for_comment(_, _), do: nil

  # Metadata a CLIENT may set on its own comment.
  #
  # Two things are taken away from it. `"giphy"` is ours. And every key the
  # host registered as a DECORATION is a privilege escalation rather than a
  # preference: `find_decoration_for_comment/2` picks which host record a
  # decoration write renames by looking the comment's metadata up in that
  # map, while `decoration_if_permitted/2` asks only "do you own this
  # COMMENT?" — which you always do, having just posted it. Without this a
  # commenter could point a fresh comment at somebody else's annotation
  # (`metadata[annotation_uuid]=<theirs>`) and rename it through a
  # `send_update` the host cannot tell from a legitimate one. The link
  # between a comment and a host record is the host's to make server-side,
  # never a client's to claim.
  defp client_metadata(params, socket) do
    case Map.get(params, "metadata") do
      # `metadata=foo` rather than `metadata[k]=v` arrives as a binary and
      # used to raise BadMapError before any validation ran.
      %{} = metadata ->
        metadata
        |> Map.delete("giphy")
        |> Map.drop(decoration_keys(socket))

      _ ->
        %{}
    end
  end

  # The metadata keys a client may never write, because they LINK a comment
  # to a host record.
  #
  # `comment_decorations` alone is not a safe source for this: it is a
  # registry of VALUES, rebuilt from data on every render, so the key is
  # absent whenever the page happens to have nothing to decorate yet — core's
  # `build_comment_decorations/1` returns `%{}` until an annotation is given
  # a title. A comment planted in that window keeps its forged link and
  # decorates the victim's record the moment a title appears. `:decoration_keys`
  # is the static declaration that does not move with the data; hosts using
  # decorations should pass it, and the registry's keys remain a floor.
  defp decoration_keys(socket) do
    declared = socket.assigns[:decoration_keys] || []
    registry = Map.keys(socket.assigns[:comment_decorations] || %{})

    Enum.uniq(declared ++ registry)
  end

  # Label for a comment's matching decoration, or "" when none. Kept
  # separate so the edit_comment handler doesn't nest a case inside its
  # permission `if` (Credo max nesting depth).
  defp decoration_label_for(comment, decorations) do
    case find_decoration_for_comment(comment, decorations) do
      %{label: label} when is_binary(label) -> label
      _ -> ""
    end
  end

  # Same as above but resolves the comment from the in-memory tree
  # by uuid first. Used by the title-only click-to-edit flow which
  # only carries the comment uuid in its phx-value-uuid.
  defp find_decoration_for_comment_uuid(comment_uuid, socket) do
    case find_comment_in_tree(socket.assigns.comments, comment_uuid) do
      nil -> nil
      comment -> find_decoration_for_comment(comment, socket.assigns.comment_decorations)
    end
  end

  # Every id reaching here comes from a client payload, so it can be
  # anything. `to_string/1` below raises Protocol.UndefinedError on a map,
  # which takes the host LiveView down with it — and four handlers
  # (toggle_like, toggle_dislike, reply_to, begin_decoration_edit) hand
  # their id straight to this function. One clause closes all of them.
  defp find_comment_in_tree(_comments, uuid) when not is_binary(uuid), do: nil

  defp find_comment_in_tree([], _uuid), do: nil

  defp find_comment_in_tree([comment | rest], uuid) do
    if to_string(comment.uuid) == to_string(uuid) do
      comment
    else
      find_comment_in_tree(comment.children || [], uuid) ||
        find_comment_in_tree(rest, uuid)
    end
  end

  defp find_comment_in_tree(_, _), do: nil

  defp toggle_reaction(%{assigns: %{current_user: nil}} = socket, _comment_uuid, _reaction) do
    {:noreply, put_flash(socket, :error, gettext("Sign in to react to comments"))}
  end

  defp toggle_reaction(socket, comment_uuid, reaction) do
    case find_comment_in_tree(socket.assigns.comments, comment_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found"))}

      %{status: "deleted"} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot react to a deleted comment"))}

      _comment ->
        user_uuid = socket.assigns.current_user.uuid
        result = apply_reaction(comment_uuid, user_uuid, reaction)

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_comments()
             |> load_reaction_state()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update reaction"))}
        end
    end
  end

  defp apply_reaction(comment_uuid, user_uuid, :like) do
    if PhoenixKitComments.comment_liked_by?(comment_uuid, user_uuid) do
      PhoenixKitComments.unlike_comment(comment_uuid, user_uuid)
    else
      PhoenixKitComments.like_comment(comment_uuid, user_uuid)
    end
  end

  defp apply_reaction(comment_uuid, user_uuid, :dislike) do
    if PhoenixKitComments.comment_disliked_by?(comment_uuid, user_uuid) do
      PhoenixKitComments.undislike_comment(comment_uuid, user_uuid)
    else
      PhoenixKitComments.dislike_comment(comment_uuid, user_uuid)
    end
  end

  defp do_create_comment(socket, base_attrs) do
    case consume_attachments(socket) do
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:ok, file_uuids} ->
        attrs = Map.put(base_attrs, :attachment_file_uuids, file_uuids)

        case PhoenixKitComments.create_comment(
               socket.assigns.resource_type,
               socket.assigns.resource_uuid,
               socket.assigns.current_user.uuid,
               attrs
             ) do
          {:ok, comment} ->
            sync_mentions(comment, socket.assigns.current_user.uuid)

            reset_leaf_draft_editor(
              socket.assigns.leaf_editor?,
              socket.assigns.id,
              socket.assigns.reply_to,
              socket.assigns.composer_open_at
            )

            send(
              self(),
              {:comments_updated,
               %{
                 resource_type: socket.assigns.resource_type,
                 resource_uuid: socket.assigns.resource_uuid,
                 action: :created
               }}
            )

            {:noreply,
             socket
             |> assign(:new_comment, "")
             |> assign(:reply_to, nil)
             |> assign(:composer_open_at, nil)
             |> assign(:giphy_selected, nil)
             |> assign(:giphy_open?, false)
             |> assign(:giphy_results, [])
             |> assign(:giphy_query, "")
             |> assign(:attach_menu_open?, false)
             |> assign(:recording_audio?, false)
             |> load_comments()
             |> put_flash(:info, gettext("Comment added"))}

          {:error, %Ecto.Changeset{} = changeset} ->
            message = first_error_message(changeset) || gettext("Failed to add comment")
            {:noreply, put_flash(socket, :error, message)}

          {:error, reason} when is_atom(reason) ->
            {:noreply, put_flash(socket, :error, create_error_message(reason))}
        end
    end
  end

  defp create_error_message(:empty_comment), do: gettext("Comment can't be empty")
  defp create_error_message(:attachments_disabled), do: gettext("Attachments are disabled")

  defp create_error_message(:too_many_attachments),
    do:
      gettext("Up to %{count} attachments per comment",
        count: PhoenixKitComments.get_max_attachments()
      )

  defp create_error_message(:max_depth_exceeded), do: gettext("Reply nesting is too deep")
  defp create_error_message(:content_too_long), do: gettext("Comment exceeds maximum length")
  defp create_error_message(:invalid_user_uuid), do: gettext("Invalid user")
  defp create_error_message(:invalid_file_uuid), do: gettext("Invalid file attachment")
  defp create_error_message(_), do: gettext("Failed to add comment")

  defp do_delete_comment(socket, comment) do
    cond do
      # First verify the comment belongs to the current resource (IDOR protection)
      comment.resource_type != socket.assigns.resource_type or
          comment.resource_uuid != socket.assigns.resource_uuid ->
        {:noreply, socket |> put_flash(:error, gettext("Invalid comment for this resource"))}

      not can_delete_comment?(socket.assigns.current_user, comment) ->
        {:noreply,
         socket |> put_flash(:error, gettext("You don't have permission to delete this comment"))}

      true ->
        execute_delete(socket, comment)
    end
  end

  defp do_save_edit(socket, comment, content) do
    max_length = PhoenixKitComments.get_max_length()
    content = String.trim(content)

    cond do
      # Empty text is only rejected when there's nothing else to the comment.
      # A GIF- or attachment-only comment is valid (the changeset agrees), so
      # clearing its text must be allowed.
      content == "" and is_nil(comment_gif(comment)) and comment_media(comment) == [] ->
        {:noreply, put_flash(socket, :error, gettext("Comment cannot be empty"))}

      String.length(content) > max_length ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Comment exceeds maximum length of %{max_length} characters",
             max_length: max_length
           )
         )}

      not can_edit_comment?(socket.assigns.current_user, comment) ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to edit this comment"))}

      true ->
        do_update_comment(socket, comment, content)
    end
  end

  defp do_update_comment(socket, comment, content) do
    # Who edited it. `update_comment/3` forwards the actor keys to the
    # activity log, and without one the trail reads "a comment was edited"
    # with nobody attached — which is every edit made from an embedded
    # thread, i.e. the path ordinary users take. The admin page has always
    # threaded it; this one did not.
    opts = [actor_uuid: actor_uuid(socket)]

    case PhoenixKitComments.update_comment(comment, %{content: content}, opts) do
      {:ok, updated} ->
        # An edit that ADDS a mention pings; one that only reshuffles text
        # already mentioning someone pings nobody, because sync/4 returns
        # what is new and delivery is claimed once.
        sync_mentions(updated, socket.assigns.current_user.uuid)

        # Same host contract as create/delete: a host showing this
        # resource's latest comments inline must see the new text without
        # a reload.
        send(
          self(),
          {:comments_updated,
           %{
             resource_type: socket.assigns.resource_type,
             resource_uuid: socket.assigns.resource_uuid,
             action: :updated
           }}
        )

        {:noreply,
         socket
         |> assign(:editing_uuid, nil)
         |> assign(:editing_content, "")
         |> load_comments()
         |> put_flash(:info, gettext("Comment updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update comment"))}
    end
  end

  defp execute_delete(socket, comment) do
    # Same reason as `do_update_comment/3`: the deletion is logged either
    # way, but an audit row without an actor cannot answer the one question
    # asked of it.
    case PhoenixKitComments.delete_comment(comment, actor_uuid: actor_uuid(socket)) do
      {:ok, _} ->
        send(
          self(),
          {:comments_updated,
           %{
             resource_type: socket.assigns.resource_type,
             resource_uuid: socket.assigns.resource_uuid,
             action: :deleted
           }}
        )

        {:noreply,
         socket
         |> load_comments()
         |> put_flash(:info, gettext("Comment deleted"))}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete comment"))}
    end
  end

  defp consume_attachments(%{assigns: %{uploads: %{attachment: %{entries: []}}}}),
    do: {:ok, []}

  defp consume_attachments(socket) do
    user_uuid = socket.assigns.current_user.uuid
    resource_type = socket.assigns.resource_type
    resource_uuid = socket.assigns.resource_uuid

    socket
    |> consume_uploaded_entries(
      :attachment,
      &store_entry(&1, &2, user_uuid, resource_type, resource_uuid)
    )
    |> partition_upload_results()
  end

  @impl true
  def handle_async(:giphy_search, {:ok, {:ok, results}}, socket) do
    {:noreply,
     socket
     |> assign(:giphy_searching?, false)
     |> assign(:giphy_results, results)}
  end

  def handle_async(:giphy_search, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:giphy_searching?, false)
     |> assign(:giphy_results, [])
     |> put_flash(:error, giphy_error_message(reason))}
  end

  def handle_async(:giphy_search, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:giphy_searching?, false)
     |> assign(:giphy_results, [])
     |> put_flash(:error, gettext("Giphy search failed. Please try again."))}
  end

  defp giphy_error_message(:giphy_disabled), do: gettext("GIFs are turned off here.")

  defp giphy_error_message(:missing_api_key),
    do: gettext("Giphy search failed. Check the API key in settings.")

  defp giphy_error_message(_other), do: gettext("Giphy search failed. Please try again.")

  # A browser-supplied filename reaches storage and, from there, download
  # headers. Path separators and control characters come out; the rest is
  # left recognisable to whoever uploaded it.
  defp safe_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\/\\]/, "")
    |> String.slice(0, 200)
    |> case do
      "" -> "attachment"
      cleaned -> cleaned
    end
  end

  defp safe_filename(_name), do: "attachment"

  defp audio_error_message("unsupported"),
    do: gettext("Microphone access is not supported by this browser.")

  defp audio_error_message("denied"), do: gettext("Microphone permission denied.")
  defp audio_error_message("start_failed"), do: gettext("Could not start recording.")
  defp audio_error_message("attach_failed"), do: gettext("Failed to attach the recording.")
  defp audio_error_message(_other), do: gettext("Recording failed. Please try again.")

  defp save_edit_for(socket, comment, content, params) do
    cond do
      comment.resource_type != socket.assigns.resource_type or
          comment.resource_uuid != socket.assigns.resource_uuid ->
        {:noreply, put_flash(socket, :error, gettext("Invalid comment for this resource"))}

      # Permission FIRST. This used to forward the decoration and then let
      # `do_save_edit/3` do the check, so a caller whose edit rights had gone
      # still landed the label on the host record while their body edit was
      # refused — half an edit, from a refused request.
      not can_edit_comment?(socket.assigns[:current_user], comment) ->
        {:noreply, put_flash(socket, :error, gettext("You cannot edit this comment"))}

      true ->
        # If the edit form carried a "label" field (i.e. the comment has a
        # matching decoration with an `on_save` action), forward the new
        # label to the parent. Both updates fire in the same tick.
        maybe_forward_decoration_update(socket, comment, params)
        do_save_edit(socket, comment, content)
    end
  end

  # Mentions ship in a core release newer than this module's declared floor,
  # so the call has to be resolved at runtime — `apply/3` is the point, not
  # an oversight, which is why the check is disabled just here.
  defp mentions_available? do
    Code.ensure_loaded?(PhoenixKit.Mentions) and
      credo_safe_apply(PhoenixKit.Mentions, :enabled?, [])
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp credo_safe_apply(mod, fun, args), do: apply(mod, fun, args)

  defp uploads_done?(entries), do: Enum.all?(entries, & &1.done?)

  defp store_entry(meta, entry, user_uuid, resource_type, resource_uuid) do
    # `client_*` is exactly that: what the browser SAID. Core's storage does
    # `Keyword.fetch!` on both and derives the stored mime type and the
    # render branch from `content_type` alone — nothing in the chain looks
    # at the bytes. So a file declaring `image/svg+xml` renders through the
    # `<img>` branch, and a declared size becomes the recorded size.
    #
    # The size is now measured, and the extension is re-derived from the
    # declared type rather than trusted from the name. Sniffing the content
    # itself belongs in core's storage, next to the other `fetch!`s — noted
    # in the sweep rather than reached around from here.
    stat_size =
      case File.stat(meta.path) do
        {:ok, %{size: size}} -> size
        _ -> entry.client_size
      end

    opts = [
      filename: safe_filename(entry.client_name),
      content_type: entry.client_type,
      size_bytes: stat_size,
      user_uuid: user_uuid
    ]

    case Storage.store_file(meta.path, opts) do
      {:ok, %Storage.File{} = file} ->
        PhoenixKitComments.Attachments.place_stored_file(
          file,
          resource_type,
          resource_uuid,
          user_uuid
        )

        {:ok, {:ok, file.uuid}}

      {:error, reason} ->
        {:ok, {:error, reason}}
    end
  end

  defp partition_upload_results(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} ->
        {:ok, Enum.map(oks, fn {:ok, uuid} -> uuid end)}

      {_, [{:error, reason} | _]} ->
        # Logged, not shown. `reason` comes back from storage as raw strings,
        # provider errors and changesets — bucket names and internal paths
        # in a banner the uploader reads.
        Logger.warning("[PhoenixKitComments] attachment upload failed: #{inspect(reason)}")
        {:error, gettext("Upload failed. Please try again.")}
    end
  end

  defp load_comments(socket) do
    comments =
      PhoenixKitComments.get_comment_tree(
        socket.assigns.resource_type,
        socket.assigns.resource_uuid
      )

    comment_count =
      PhoenixKitComments.count_comments(
        socket.assigns.resource_type,
        socket.assigns.resource_uuid,
        status: "published"
      )

    socket
    |> assign(:comments, comments)
    |> assign(:comment_count, comment_count)
  end

  defp load_reaction_state(%{assigns: %{show_likes: false}} = socket) do
    socket
    |> assign(:liked_comment_uuids, MapSet.new())
    |> assign(:disliked_comment_uuids, MapSet.new())
  end

  defp load_reaction_state(%{assigns: %{current_user: nil}} = socket) do
    socket
    |> assign(:liked_comment_uuids, MapSet.new())
    |> assign(:disliked_comment_uuids, MapSet.new())
  end

  defp load_reaction_state(socket) do
    comment_uuids = comment_tree_uuids(socket.assigns.comments)
    user_uuid = socket.assigns.current_user.uuid

    socket
    |> assign(
      :liked_comment_uuids,
      PhoenixKitComments.list_user_liked_comment_uuids(user_uuid, comment_uuids)
      |> MapSet.new()
    )
    |> assign(
      :disliked_comment_uuids,
      PhoenixKitComments.list_user_disliked_comment_uuids(user_uuid, comment_uuids)
      |> MapSet.new()
    )
  end

  defp comment_tree_uuids(comments) when is_list(comments) do
    Enum.flat_map(comments, fn comment ->
      [comment.uuid | comment_tree_uuids(comment.children || [])]
    end)
  end

  defp reaction_active?(comment_uuids, comment_uuid) do
    MapSet.member?(comment_uuids, comment_uuid)
  end

  # Heuristic for "this comment body is long enough to clamp + offer Read more":
  # several lines, or a long single block that would wrap past the clamp.
  # Rewrites @ and # tokens as markdown for the person reading. A no-op
  # when core is too old to have mentions, or the text has none.
  defp resolve_mentions(content, assigns) do
    # Called from `render_comment/1`, a FUNCTION component — it sees only its
    # declared attrs, never the LiveComponent's assigns. Passing that
    # component's own `assigns` here read `pk_scope` and
    # `withhold_mention_titles` as nil on every render, and because these are
    # bracket lookups it failed silently instead of raising: the withhold
    # feature was a no-op, and a nil scope made `Mentions.visible/3` fail
    # closed, so every mention rendered locked WITH its title still printed —
    # the exact leak withholding exists to prevent.
    #
    # `@ctx` is the parent's full assigns, forwarded at both call sites, so
    # both values are really there. Same class as the KeyError fixed in
    # ff6c378; that pass missed this one because nothing crashed.
    if Code.ensure_loaded?(PhoenixKit.Mentions) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKit.Mentions, :to_markdown, [
        content,
        [
          scope: assigns[:pk_scope],
          user_uuid: assigns[:current_user] && assigns.current_user.uuid,
          withhold_titles: assigns[:withhold_mention_titles] == true
        ]
      ])
    else
      content
    end
  rescue
    _ -> content
  end

  # Indexes the comment's mentions and delivers its @ pings — on the
  # durable create, never on a draft keystroke. Wrapped so a mention
  # failure can never cost someone their comment.
  defp sync_mentions(comment, actor_uuid) do
    if Code.ensure_loaded?(PhoenixKit.Mentions) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PhoenixKit.Mentions, :sync, [
             "comment",
             comment.uuid,
             comment.content,
             [field: "content", actor_uuid: actor_uuid]
           ]) do
        {:ok, new} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(PhoenixKit.Mentions, :notify, [
            new,
            [
              source_type: comment.resource_type,
              source_uuid: comment.resource_uuid,
              preview: comment.content
            ]
          ])

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # A full scope for the person reading, so a handler can answer questions
  # that need permissions (a site admin sees more than their memberships).
  # nil for an anonymous reader, which resolves to "sees nothing private".
  defp viewer_scope(nil), do: nil

  defp viewer_scope(user) do
    Scope.for_user(user)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp long_comment?(content) when is_binary(content) do
    trimmed = String.trim(content)
    String.length(trimmed) > 280 or length(String.split(trimmed, "\n")) > 4
  end

  defp long_comment?(_content), do: false

  attr(:comment, :map, required: true)
  attr(:current_user, :map, required: true)
  attr(:myself, :any, required: true)
  attr(:component_id, :string, required: true)
  attr(:editing_uuid, :string, default: nil)
  attr(:editing_content, :string, default: "")
  attr(:comment_decorations, :map, default: %{})
  attr(:editing_decoration_uuid, :any, default: nil)
  attr(:editing_decoration_value, :string, default: "")
  attr(:show_likes, :boolean, default: true)
  attr(:liked_comment_uuids, :any, required: true)
  attr(:disliked_comment_uuids, :any, required: true)
  attr(:reply_to, :string, default: nil)
  # Full component assigns, forwarded so the inline reply form can reuse
  # composer_form/1 (Leaf editor, attach menu, GIF picker, audio, char
  # counter). Threaded through the recursive children call below.
  attr(:ctx, :map, required: true)

  defp render_comment(assigns) do
    decoration = find_decoration_for_comment(assigns.comment, assigns.comment_decorations)

    # Convenience: the pre-existing data-annotation-uuid attr on the
    # rendered wrapper. Kept for callers that target shapes via that
    # selector (predates the decoration refactor).
    annotation_uuid = get_in(assigns.comment.metadata || %{}, ["annotation_uuid"])

    assigns =
      assigns
      |> assign(:decoration, decoration)
      |> assign(:annotation_uuid, annotation_uuid)
      |> assign(
        :decoration_editing?,
        decoration && match?({_, _}, assigns.editing_decoration_uuid) &&
          assigns.editing_decoration_uuid ==
            {decoration.metadata_key, assigns.comment.uuid}
      )

    ~H"""
    <div
      data-comment-uuid={@comment.uuid}
      data-annotation-uuid={@annotation_uuid}
      class={[
        if(@comment.depth > 0, do: "ml-2 sm:ml-4 border-l-2 border-base-300", else: "")
      ]}
    >
      <div class="group/comment bg-base-200 rounded-lg p-3 sm:p-4">
        <%= if @comment.status == "deleted" do %>
          <div class="text-sm text-base-content/50 italic">{gettext("[removed]")}</div>
        <% else %>
        <%!-- Comment Header — avatar + email only. Date moves below the    --%>
        <%!-- body and actions sit in a footer row so a narrow embed        --%>
        <%!-- container (sidebar, info panel) can't squeeze the email into  --%>
        <%!-- "te…" with the action buttons hogging the row.                 --%>
        <div class="flex items-center gap-2 text-sm mb-2 min-w-0">
          <.icon name="hero-user-circle" class="w-5 h-5 text-base-content/60 shrink-0" />
          <span class="font-semibold truncate min-w-0">
            <%= if @comment.user do %>
              {author_name(@comment)}
            <% else %>
              {gettext("Unknown")}
            <% end %>
          </span>
          <%!-- "…" actions menu — Edit / Delete live here, top right,     --%>
          <%!-- revealed on hover (focus-within keeps an OPEN menu and     --%>
          <%!-- keyboard users visible) so a card at rest is just          --%>
          <%!-- author / body / reactions.                                  --%>
          <% may_edit = can_edit_comment?(@current_user, @comment, @ctx.viewer_is_admin?) %>
          <% may_delete = can_delete_comment?(@current_user, @comment, @ctx.viewer_is_admin?) %>
          <%= if may_edit or may_delete do %>
            <%!-- `[@media(hover:none)]` is the touch escape hatch: a device --%>
            <%!-- with no hover never matches `group-hover`, so Edit and     --%>
            <%!-- Delete were unreachable on a phone or tablet — the control --%>
            <%!-- rendered, at zero opacity, and nothing the user could do   --%>
            <%!-- revealed it. Coarse pointers get the row at rest.          --%>
            <div class="dropdown dropdown-end ml-auto shrink-0 opacity-0 group-hover/comment:opacity-100 focus-within:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity">
              <div
                tabindex="0"
                role="button"
                class="btn btn-ghost btn-xs"
                aria-label={gettext("Comment actions")}
              >
                <.icon name="hero-ellipsis-horizontal" class="w-4 h-4" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu menu-sm bg-base-100 rounded-box z-20 w-40 p-1 shadow"
              >
                <%!-- The dropdown is focus-driven (daisyUI), and LiveView's --%>
                <%!-- patch doesn't move focus — so after Edit opens the form  --%>
                <%!-- or Delete removes the card, the menu would just stay     --%>
                <%!-- open. Blurring on click closes it the moment an action   --%>
                <%!-- is chosen (before the data-confirm dialog, which is      --%>
                <%!-- fine either way the user answers).                       --%>
                <li :if={may_edit}>
                  <button
                    phx-click="edit_comment"
                    phx-value-id={@comment.uuid}
                    phx-target={@myself}
                    onclick="document.activeElement && document.activeElement.blur()"
                  >
                    <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
                  </button>
                </li>
                <li :if={may_delete}>
                  <button
                    phx-click="delete_comment"
                    phx-disable-with={gettext("Deleting...")}
                    phx-value-id={@comment.uuid}
                    phx-target={@myself}
                    class="text-error"
                    data-confirm={gettext("Are you sure you want to delete this comment?")}
                    onclick="document.activeElement && document.activeElement.blur()"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
                  </button>
                </li>
              </ul>
            </div>
          <% end %>
        </div>

        <%!-- Decoration label (when this comment matches an entry in   --%>
        <%!-- :comment_decorations). Sits BETWEEN the user-info         --%>
        <%!-- header and the comment body so the hierarchy reads:       --%>
        <%!-- who/when → topic → comment.                                --%>
        <%!--                                                            --%>
        <%!-- Read-only when the decoration's `:on_save` is nil;        --%>
        <%!-- click-to-edit when set. The pencil icon only appears on   --%>
        <%!-- hover so the header doesn't shout "edit me" until the     --%>
        <%!-- user reaches it.                                           --%>
        <%!--                                                            --%>
        <%!-- Suppressed during comment-edit (@editing_uuid matches) —  --%>
        <%!-- the unified edit form below carries its own label input.  --%>
        <%= if @decoration && @editing_uuid != @comment.uuid do %>
          <div class="mt-2 mb-2">
            <%= if @decoration_editing? do %>
              <.form
                for={%{}}
                id={"decoration-form-#{@myself}-#{@comment.uuid}"}
                phx-submit="save_decoration"
                phx-target={@myself}
                class="flex items-center gap-2"
              >
                <input type="hidden" name="uuid" value={@comment.uuid} />
                <input
                  type="text"
                  name="label"
                  value={@editing_decoration_value}
                  maxlength="200"
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  phx-keydown="cancel_decoration_edit"
                  phx-key="escape"
                  phx-target={@myself}
                  class="input input-sm flex-1 text-base font-bold"
                />
                <button
                  type="submit"
                  phx-disable-with={gettext("Saving…")}
                  class="btn btn-primary btn-xs"
                >
                  <.icon name="hero-check" class="w-3.5 h-3.5" />
                </button>
                <button
                  type="button"
                  phx-click="cancel_decoration_edit"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </.form>
            <% else %>
              <div
                class={[
                  "group flex items-center gap-1",
                  @decoration.on_save && "cursor-pointer"
                ]}
                phx-click={@decoration.on_save && "begin_decoration_edit"}
                phx-value-uuid={@comment.uuid}
                phx-target={@myself}
              >
                <h4 class={[
                  "text-base font-bold break-words flex-1 min-w-0",
                  @decoration.on_save && "group-hover:text-primary transition-colors"
                ]}>
                  {@decoration.label}
                </h4>
                <%= if @decoration.on_save do %>
                  <.icon
                    name="hero-pencil-square"
                    class="w-3.5 h-3.5 opacity-0 group-hover:opacity-60 [@media(hover:none)]:opacity-60 shrink-0 transition-opacity"
                  />
                <% end %>
              </div>
            <% end %>
            <hr class="mt-1 border-base-300" />
          </div>
        <% end %>

        <%!-- Comment Content (or Edit Form) --%>
        <%= if @editing_uuid == @comment.uuid do %>
          <.form
            for={%{}}
            id={"comment-edit-form-#{@myself}-#{@comment.uuid}"}
            phx-submit="save_edit"
            phx-target={@myself}
            class="space-y-2"
          >
            <%!-- When this comment has a decoration with an `on_save`    --%>
            <%!-- action, the edit form opens label + body together.      --%>
            <%!-- Save writes both: comment content through the normal    --%>
            <%!-- `do_save_edit` path, decoration label via send_update   --%>
            <%!-- to the parent. The standalone click-the-label flow      --%>
            <%!-- above stays as a shortcut for "just rename, don't       --%>
            <%!-- re-edit the body."                                       --%>
            <%= if @decoration && @decoration.on_save do %>
              <input
                type="text"
                name="label"
                value={@editing_decoration_value}
                maxlength="200"
                placeholder={gettext("Title")}
                class="input input-sm w-full text-base font-bold"
              />
              <hr class="border-base-300" />
            <% end %>
            <%!-- Edit body. Leaf when available, plain textarea fallback. --%>
            <%!-- Editor id encodes the comment uuid so morphdom remounts  --%>
            <%!-- a fresh Leaf when the user opens edit on a different     --%>
            <%!-- comment. Save reads from socket.assigns.editing_content   --%>
            <%!-- (kept fresh via forwarded :leaf_changed events).         --%>
            <%= if @ctx.leaf_editor? do %>
              <.live_component
                module={Leaf}
                id={edit_editor_id(@component_id, @comment.uuid)}
                content={@editing_content || ""}
                mode={@ctx.editor_mode}
                preset={:advanced}
                placeholder={gettext("Edit your comment...")}
                height="200px"
                debounce={400}
                upload_handler={nil}
                sync_input_name="content"
                loading_preset={:random}
                loading_text={nil}
              />
            <% else %>
              <textarea
                name="content"
                class="textarea w-full"
                rows="3"
                required
                phx-hook={@ctx.mentions_on && "MentionInput"}
                id={@ctx.mentions_on && "#{@ctx.id}-edit-comment"}
              ><%= @editing_content %></textarea>
            <% end %>
            <div class="flex flex-wrap justify-end gap-2">
              <button
                type="button"
                phx-click="cancel_edit"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                phx-disable-with={gettext("Saving…")}
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-check" class="w-4 h-4 mr-1" /> {gettext("Save")}
              </button>
            </div>
          </.form>
        <% else %>
          <%= if @comment.content && @comment.content != "" do %>
            <% expanded = MapSet.member?(@ctx.expanded_comments, @comment.uuid) %>
            <% is_long = long_comment?(@comment.content) %>
            <div class="text-base-content break-words pk-comment-md">
              <%!-- Mentions resolve for THIS reader before markdown runs:
                   a link if they may open it, the author's words if it's
                   gone, "no access" if it isn't theirs. --%>
              <.comment_markdown
                content={resolve_mentions(@comment.content, @ctx)}
                compact
                class={if(is_long and not expanded, do: "line-clamp-4", else: "")}
              />
            </div>
            <button
              :if={is_long}
              type="button"
              phx-click="toggle_comment_expanded"
              phx-value-uuid={@comment.uuid}
              phx-target={@myself}
              class="mt-1 inline-flex items-center gap-0.5 text-sm font-semibold text-primary hover:underline"
            >
              {if expanded, do: gettext("Show less"), else: gettext("Read more")}
              <.icon
                name={if expanded, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
                class="w-4 h-4"
              />
            </button>
          <% end %>
          <%= if gif = comment_gif(@comment) do %>
            <div class="mt-2">
              <img
                src={gif["url"]}
                loading="lazy"
                alt={gettext("GIF")}
                class="rounded-lg w-full max-w-xs h-auto"
              />
            </div>
          <% end %>

          <%= if comment_media(@comment) != [] do %>
            <div class="mt-2 space-y-2">
              <%= for media <- comment_media(@comment) do %>
                <.render_attachment media={media} />
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%!-- Footer — date on its own row above the action buttons, both --%>
        <%!-- stacked under the body. Narrow embeds get a stable layout    --%>
        <%!-- (email never truncates under action chips), wide embeds keep --%>
        <%!-- the action row from looking centered next to a half-empty    --%>
        <%!-- email line.                                                   --%>
        <div class="text-xs text-base-content/60 mt-2">
          {Calendar.strftime(@comment.inserted_at, "%b %d, %Y %I:%M %p")}
        </div>

        <%!-- Bottom-right action row: Reply first (hover-revealed —     --%>
        <%!-- focus-visible keeps keyboard users covered), reactions     --%>
        <%!-- always visible so counts read at rest without the row      --%>
        <%!-- feeling crowded.                                            --%>
        <div class="flex flex-wrap items-center justify-end gap-1.5 mt-2">
          <button
            phx-click="reply_to"
            phx-value-id={@comment.uuid}
            phx-target={@myself}
            class="btn btn-ghost btn-xs opacity-0 group-hover/comment:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity"
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Reply")}
          </button>

          <%= if @show_likes do %>
            <button
              type="button"
              phx-click="toggle_like"
              phx-value-id={@comment.uuid}
              phx-target={@myself}
              disabled={is_nil(@current_user)}
              title={gettext("Like")}
              class={[
                "btn btn-xs",
                reaction_active?(@liked_comment_uuids, @comment.uuid) && "btn-primary",
                !reaction_active?(@liked_comment_uuids, @comment.uuid) && "btn-ghost"
              ]}
            >
              <.icon name="hero-hand-thumb-up" class="w-4 h-4" />
              <span>{@comment.like_count || 0}</span>
            </button>

            <button
              type="button"
              phx-click="toggle_dislike"
              phx-value-id={@comment.uuid}
              phx-target={@myself}
              disabled={is_nil(@current_user)}
              title={gettext("Dislike")}
              class={[
                "btn btn-xs",
                reaction_active?(@disliked_comment_uuids, @comment.uuid) && "btn-primary",
                !reaction_active?(@disliked_comment_uuids, @comment.uuid) && "btn-ghost"
              ]}
            >
              <.icon name="hero-hand-thumb-down" class="w-4 h-4" />
              <span>{@comment.dislike_count || 0}</span>
            </button>
          <% end %>
        </div>
        <% end %>

        <%= if @reply_to == @comment.uuid do %>
          <div class="mt-3 border-l-2 border-primary/40 pl-3">
            <div class="text-xs font-medium text-base-content/60 mb-2">{gettext("Replying here")}</div>
            <%!-- Same composer body as the top/bottom "Write comment"     --%>
            <%!-- form (Leaf editor + attach menu + GIF picker + audio),   --%>
            <%!-- scoped to this comment's reply editor id. Replies now    --%>
            <%!-- reach feature parity with top-level comments.             --%>
            <.composer_form
              ctx={@ctx}
              editor_id={reply_editor_id(@component_id, @comment.uuid)}
              suffix={@comment.uuid}
              placeholder={gettext("Write a reply...")}
              submit_label={gettext("Post Reply")}
            />
          </div>
        <% end %>

        <%!-- Nested Comments (Replies) --%>
        <%= if @comment.children && length(@comment.children) > 0 do %>
          <div class="mt-4 space-y-3">
            <%= for child <- @comment.children do %>
              <.render_comment
                comment={child}
                current_user={@current_user}
                myself={@myself}
                component_id={@component_id}
                editing_uuid={@editing_uuid}
                editing_content={@editing_content}
                comment_decorations={@comment_decorations}
                editing_decoration_uuid={@editing_decoration_uuid}
                editing_decoration_value={@editing_decoration_value}
                show_likes={@show_likes}
                liked_comment_uuids={@liked_comment_uuids}
                disliked_comment_uuids={@disliked_comment_uuids}
                reply_to={@reply_to}
                ctx={@ctx}
              />
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:media, :map, required: true)

  defp render_attachment(%{media: %{file: %{file_type: "image"} = file}} = assigns) do
    assigns = assign(assigns, :src, signed_url(file, "medium"))

    ~H"""
    <a
      href={signed_url(@media.file, "original")}
      target="_blank"
      rel="noopener"
      class="block"
    >
      <img
        src={@src}
        loading="lazy"
        alt={@media.caption || @media.file.original_file_name}
        class="rounded-lg w-full h-auto max-h-96 object-contain"
      />
    </a>
    """
  end

  defp render_attachment(%{media: %{file: %{file_type: "video"} = file}} = assigns) do
    assigns =
      assigns
      |> assign(:src, signed_url(file, "original"))
      |> assign(:poster, signed_url(file, "video_thumbnail"))

    ~H"""
    <video controls preload="metadata" poster={@poster} class="rounded-lg max-w-md w-full">
      <source src={@src} type={@media.file.mime_type} />
      {gettext("Your browser does not support video playback.")}
    </video>
    """
  end

  defp render_attachment(%{media: %{file: %{file_type: "audio"} = file}} = assigns) do
    assigns = assign(assigns, :src, signed_url(file, "original"))

    ~H"""
    <audio controls preload="metadata" class="w-full max-w-md">
      <source src={@src} type={@media.file.mime_type} />
      {gettext("Your browser does not support audio playback.")}
    </audio>
    """
  end

  defp render_attachment(%{media: %{file: file}} = assigns) do
    assigns =
      assigns
      |> assign(:href, signed_url(file, "original"))
      |> assign(:size_kb, div(file.size || 0, 1024))

    ~H"""
    <a
      href={@href}
      download={@media.file.original_file_name}
      class="inline-flex items-center gap-2 px-3 py-2 bg-base-200 rounded hover:bg-base-300"
    >
      <.icon name="hero-document-arrow-down" class="w-5 h-5 shrink-0" />
      <div class="min-w-0">
        <div class="text-sm font-medium truncate">{@media.file.original_file_name}</div>
        <div class="text-xs text-base-content/60">{@size_kb} KB</div>
      </div>
    </a>
    """
  end

  defp signed_url(%{uuid: uuid}, variant),
    do: URLSigner.signed_url(to_string(uuid), variant)

  defp comment_media(%{media: media}) when is_list(media), do: media
  defp comment_media(_), do: []

  # A decoration write forwards to the HOST component (`on_save`), which then
  # renames one of its own records — so this is a write on somebody else's
  # data with nothing but the pencil icon in front of it. Neither handler
  # checked anything at all: a logged-out visitor could push `save_decoration`
  # at the component and rename any annotation on the page, and the
  # `send_update` the host receives is byte-identical to a legitimate one.
  #
  # Gated on the same rule as editing the comment itself, which is the
  # closest existing answer to "may this person change what this comment
  # says".
  defp decoration_if_permitted(comment_uuid, socket) do
    with %{} = decoration <- find_decoration_for_comment_uuid(comment_uuid, socket),
         %{} = comment <- find_comment_in_tree(socket.assigns.comments, comment_uuid),
         true <- can_edit_comment?(socket.assigns[:current_user], comment) do
      decoration
    else
      _ -> nil
    end
  end

  # Two arities on purpose. The 2-arity form is the AUTHORIZATION boundary,
  # called once per event from the handlers, and resolves the role itself.
  # The 3-arity form takes an already-resolved `admin?` and is what the
  # RENDER path uses: `user_is_admin?/1` is two `exists?` queries, and
  # render_comment/1 recurses per reply and asks four times per comment, so
  # a fifty-comment thread was hundreds of role queries on every re-render.
  # Same reasoning as `:pk_scope` above — resolve once per render, not once
  # per comment.
  defp can_edit_comment?(nil, _comment), do: false

  defp can_edit_comment?(user, comment),
    do: can_edit_comment?(user, comment, user_is_admin?(user))

  defp can_edit_comment?(nil, _comment, _admin?), do: false
  defp can_edit_comment?(user, comment, admin?), do: user.uuid == comment.user_uuid or admin?

  defp can_delete_comment?(nil, _comment), do: false

  defp can_delete_comment?(user, comment),
    do: can_delete_comment?(user, comment, user_is_admin?(user))

  defp can_delete_comment?(nil, _comment, _admin?), do: false
  defp can_delete_comment?(user, comment, admin?), do: user.uuid == comment.user_uuid or admin?

  defp user_is_admin?(nil), do: false

  defp user_is_admin?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp comment_gif(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "giphy") do
      %{"url" => url} = gif when is_binary(url) and url != "" -> gif
      _ -> nil
    end
  end

  defp comment_gif(_), do: nil

  defp first_error_message(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{field, {msg, _opts}} | _] -> "#{Phoenix.Naming.humanize(field)} #{msg}"
      _ -> nil
    end
  end

  defp attachment_icon("image/" <> _), do: "hero-photo"
  defp attachment_icon("video/" <> _), do: "hero-film"
  defp attachment_icon("audio/" <> _), do: "hero-musical-note"
  defp attachment_icon(_), do: "hero-document"

  defp upload_error_label(:too_large), do: gettext("File too large")
  defp upload_error_label(:too_many_files), do: gettext("Too many files")
  defp upload_error_label(:not_accepted), do: gettext("File type not allowed")

  defp upload_error_label(other),
    do: gettext("Upload error: %{reason}", reason: inspect(other))

  # ── Leaf editor integration ──────────────────────────────────
  # Leaf (the optional rich-text editor) is a LiveComponent that
  # sends `{:leaf_changed, %{editor_id, markdown, html}}` to
  # `self()` — i.e. the parent LiveView process, NOT the
  # CommentsComponent (which is itself a LiveComponent). Host LVs
  # that embed CommentsComponent must catch those messages and
  # call `forward_leaf_event/2` so the component can keep its
  # draft / edit assigns in sync. Without forwarding, Leaf still
  # works visually but the form has no content to submit.
  #
  # ## Host wiring (one-liner per LiveView)
  #
  #     def handle_info({:leaf_changed, _} = msg, socket) do
  #       PhoenixKitComments.Web.CommentsComponent.forward_leaf_event(msg, socket)
  #     end
  #
  # ## Editor ID namespace
  #
  # The component owns the editor IDs and gates them with
  # `"pk-comments:<component_id>:..."` so the forwarder routes
  # only its own events. Other Leaf instances in the same host LV
  # (e.g. a post-content editor) are passed through unchanged via
  # `:pass`, letting the host's own handler match them.

  @doc """
  Forward a Leaf content-changed message from a host LiveView's
  `handle_info` into the comments component. Routes only events
  whose `editor_id` starts with `"pk-comments:"`; returns `:pass`
  for unrelated editors so the caller can fall through to its own
  handler.

  ## Example

      def handle_info({:leaf_changed, _} = msg, socket) do
        PhoenixKitComments.Web.CommentsComponent.forward_leaf_event(msg, socket)
      end

  Returns `{:noreply, socket}` on a match (already wrapped, ready
  to return from handle_info), or `:pass` when the editor isn't
  ours.
  """
  def forward_leaf_event(
        {:leaf_changed, %{editor_id: editor_id, markdown: markdown}},
        socket
      )
      when is_binary(editor_id) do
    case parse_editor_id(editor_id) do
      {:ok, component_id, kind} ->
        Phoenix.LiveView.send_update(__MODULE__,
          id: component_id,
          leaf_content_changed: %{kind: kind, content: markdown || ""}
        )

        {:noreply, socket}

      :pass ->
        :pass
    end
  end

  def forward_leaf_event(_msg, _socket), do: :pass

  # Parse "pk-comments:<component_id>:<kind>(:rest...)" into
  # `{:ok, component_id, kind}`. The kind is `:draft` for the
  # new-comment / reply form (one per component) or `:edit` for
  # the inline edit form (also one at a time per component).
  defp parse_editor_id("pk-comments:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      # Draft editor ids carry their composer position
      # ("...:draft:top" / "...:draft:bottom"); the position doesn't
      # change the forwarding kind, so both map to :draft.
      [component_id, "draft", _position] -> {:ok, component_id, :draft}
      [component_id, "reply", _comment_uuid] -> {:ok, component_id, :reply}
      [component_id, "edit", _comment_uuid] -> {:ok, component_id, :edit}
      _ -> :pass
    end
  end

  defp parse_editor_id(_), do: :pass

  # Shared comment-form body used by both the top/bottom composer and the
  # inline reply form. Everything inside `<.form>` (editor, char counter,
  # attach menu, GIF picker, audio recorder, staged-media list, submit
  # row) is identical between the two; only the editor id, the per-form
  # DOM-id suffix, the placeholder, and the submit label differ, so those
  # are parameters. `with_extras` gates the host `form_extras` slot — it
  # renders only on the primary composer, not on replies (preserves the
  # pre-dedup reply behavior, which never rendered it).
  attr(:ctx, :map, required: true)
  attr(:editor_id, :string, required: true)
  attr(:suffix, :any, required: true)
  attr(:placeholder, :string, required: true)
  attr(:submit_label, :string, required: true)
  attr(:with_extras, :boolean, default: false)

  defp composer_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      id={"comment-composer-#{@ctx.myself}-#{@suffix}"}
      phx-submit="add_comment"
      phx-change="update_comment_draft"
      phx-target={@ctx.myself}
      class="space-y-2"
    >
      <%!-- Comment editor. When the optional :leaf dep is present,    --%>
      <%!-- render the rich-text Leaf editor; the host LV must forward --%>
      <%!-- {:leaf_changed, ...} via forward_leaf_event/2 so the       --%>
      <%!-- content syncs to socket.assigns.new_comment for submit.    --%>
      <%!-- Without leaf, fall back to the original plain textarea.     --%>
      <%= if @ctx.leaf_editor? do %>
        <.live_component
          module={Leaf}
          id={@editor_id}
          content={@ctx.new_comment || ""}
          mode={@ctx.editor_mode}
          preset={:advanced}
          placeholder={@placeholder}
          height="200px"
          debounce={400}
          upload_handler={nil}
          sync_input_name="comment"
          loading_preset={:random}
          loading_text={nil}
        />
      <% else %>
        <textarea
          name="comment"
          placeholder={@placeholder}
          class="textarea w-full"
          rows="3"
          phx-debounce="150"
          phx-hook={@ctx.mentions_on && "MentionInput"}
          id={@ctx.mentions_on && "#{@ctx.id}-new-comment"}
        ><%= @ctx.new_comment %></textarea>
        <p :if={@ctx.mentions_on} class="text-xs opacity-50">
          {gettext("Type @ to mention someone, # to link a record.")}
        </p>
      <% end %>

      <div class={[
        "text-xs text-right",
        if(String.length(@ctx.new_comment) > @ctx.max_length,
          do: "text-error font-semibold",
          else: "text-base-content/60"
        )
      ]}>
        {String.length(@ctx.new_comment)} / {@ctx.max_length}
      </div>

      <%!-- Speaking for the project, not about it. Rendered only when the
            host supplied a verifier AND that verifier says this person
            qualifies right now — no control, no hint, for everyone else.
            The checked state is a suggestion; `resolve_attribution/2` asks
            again at submit and quietly downgrades a stale claim. --%>
      <label
        :if={project_voice_offered?(@ctx)}
        class="label cursor-pointer justify-start gap-2 py-1"
      >
        <input
          type="checkbox"
          name="post_as_project"
          class="checkbox checkbox-sm"
          checked={@ctx.project_attribution[:default_on] == true}
        />
        <span class="fieldset-legend text-sm">
          {gettext("Post as %{project}", project: @ctx.project_attribution[:label])}
        </span>
      </label>

      <%= if @with_extras and @ctx.form_extras != [], do: render_slot(@ctx.form_extras) %>

      <%!-- Persistent: recorder hook + live file input. Both must
           stay in the DOM across menu open/close so the upload
           state and MediaRecorder lifecycle survive. --%>
      <%= if @ctx.attachments_enabled? do %>
        <div
          id={"audio-recorder-#{@ctx.myself}-#{@suffix}"}
          phx-hook="PhoenixKitCommentsAudioRecorder"
          phx-target={@ctx.myself}
          data-upload-name="attachment"
          class="hidden"
        />
        <.live_file_input upload={@ctx.uploads.attachment} class="sr-only" />
      <% end %>

      <%!-- Staged media (uploads + selected GIF) --%>
      <%= if (@ctx.attachments_enabled? and (@ctx.uploads.attachment.entries != [] or @ctx.uploads.attachment.errors != [])) or @ctx.giphy_selected do %>
        <div class="space-y-2">
          <%= if @ctx.giphy_selected do %>
            <div class="flex items-center gap-3 bg-base-200 rounded p-2">
              <img
                src={@ctx.giphy_selected["preview_url"]}
                class="w-10 h-10 object-cover rounded shrink-0"
                alt=""
              />
              <div class="flex-1 min-w-0 text-sm font-medium truncate">{gettext("GIF")}</div>
              <button
                type="button"
                phx-click="remove_giphy"
                phx-target={@ctx.myself}
                class="btn btn-ghost btn-xs"
                aria-label={gettext("Remove GIF")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          <% end %>

          <%= for entry <- @ctx.uploads.attachment.entries do %>
            <div class="flex items-center gap-3 bg-base-200 rounded p-2">
              <.icon
                name={attachment_icon(entry.client_type)}
                class="w-5 h-5 shrink-0 text-base-content/60"
              />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate">{entry.client_name}</div>
                <%= if entry.progress > 0 and entry.progress < 100 do %>
                  <progress
                    class="progress progress-primary w-full h-1"
                    value={entry.progress}
                    max="100"
                  ></progress>
                <% end %>
              </div>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                phx-target={@ctx.myself}
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          <% end %>

          <%= for err <- upload_errors(@ctx.uploads.attachment) do %>
            <p class="text-xs text-error">{upload_error_label(err)}</p>
          <% end %>
          <%= for entry <- @ctx.uploads.attachment.entries, err <- upload_errors(@ctx.uploads.attachment, entry) do %>
            <p class="text-xs text-error">
              {entry.client_name}: {upload_error_label(err)}
            </p>
          <% end %>
        </div>
      <% end %>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <%= cond do %>
            <% @ctx.recording_audio? -> %>
              <button
                type="button"
                onclick="window.dispatchEvent(new CustomEvent('phx-kit-comments-audio-toggle'))"
                aria-label={gettext("Stop recording")}
                class="btn btn-sm btn-error gap-1"
              >
                <span class="inline-block w-2 h-2 rounded-full bg-base-100 animate-pulse"></span>
                <.icon name="hero-stop-circle" class="w-4 h-4" /> {gettext("Stop recording")}
              </button>

            <% @ctx.attachments_enabled? or @ctx.giphy_enabled? -> %>
              <div class="relative inline-block">
                <button
                  type="button"
                  phx-click="toggle_attach_menu"
                  phx-target={@ctx.myself}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@ctx.attach_menu_open?)}
                  aria-label={gettext("Attach media")}
                  title={gettext("Attach media")}
                  class={[
                    "btn btn-sm",
                    if(@ctx.attach_menu_open?, do: "btn-primary", else: "btn-ghost")
                  ]}
                >
                  <.icon name="hero-paper-clip" class="w-5 h-5" />
                </button>

                <%= if @ctx.attach_menu_open? do %>
                  <ul
                    phx-click-away="close_attach_menu"
                    phx-window-keydown="close_attach_menu"
                    phx-key="escape"
                    phx-target={@ctx.myself}
                    role="menu"
                    aria-label={gettext("Attach media options")}
                    class="absolute top-full left-0 mt-1 z-50 menu menu-sm bg-base-100 rounded-box shadow-lg border border-base-300 w-48 p-1"
                  >
                    <%= if @ctx.giphy_enabled? do %>
                      <li role="none">
                        <button
                          type="button"
                          role="menuitem"
                          phx-click="open_giphy_from_menu"
                          phx-target={@ctx.myself}
                          class="flex items-center gap-2"
                        >
                          <.icon name="hero-film" class="w-4 h-4" /> {gettext("GIF")}
                        </button>
                      </li>
                    <% end %>

                    <%= if @ctx.attachments_enabled? do %>
                      <li role="none">
                        <label
                          for={@ctx.uploads.attachment.ref}
                          role="menuitem"
                          phx-click="close_attach_menu"
                          phx-target={@ctx.myself}
                          class="flex items-center gap-2 cursor-pointer"
                          title={
                            gettext("Up to %{count} files, max %{size}MB each",
                              count: @ctx.max_attachments,
                              size: @ctx.max_attachment_size_mb
                            )
                          }
                        >
                          <.icon name="hero-photo" class="w-4 h-4" /> {gettext("Image")}
                        </label>
                      </li>

                      <li role="none">
                        <button
                          type="button"
                          role="menuitem"
                          onclick="window.dispatchEvent(new CustomEvent('phx-kit-comments-audio-toggle'))"
                          phx-click="close_attach_menu"
                          phx-target={@ctx.myself}
                          class="flex items-center gap-2"
                        >
                          <.icon name="hero-microphone" class="w-4 h-4" /> {gettext("Record")}
                        </button>
                      </li>
                    <% end %>
                  </ul>
                <% end %>

                <%= if @ctx.giphy_open? do %>
                  <div
                    class="pk-giphy-backdrop"
                    phx-click="close_giphy_picker"
                    phx-target={@ctx.myself}
                  >
                    <div
                      phx-click="noop"
                      phx-target={@ctx.myself}
                      phx-window-keydown="close_giphy_picker"
                      phx-key="escape"
                      role="dialog"
                      aria-modal="true"
                      aria-label={gettext("Giphy picker")}
                      class="pk-giphy-picker p-3 shadow-lg bg-base-100 rounded-box border border-base-300"
                    >
                      <label for={"giphy-search-#{@ctx.myself}-#{@suffix}"} class="sr-only">
                        {gettext("Search GIFs")}
                      </label>
                      <input
                        id={"giphy-search-#{@ctx.myself}-#{@suffix}"}
                        type="text"
                        name="q"
                        value={@ctx.giphy_query}
                        placeholder={gettext("Search GIFs...")}
                        aria-label={gettext("Search GIFs")}
                        class="input input-sm w-full"
                        phx-keyup="giphy_search"
                        phx-target={@ctx.myself}
                        phx-debounce="300"
                        onkeydown="if(event.key === 'Enter') event.preventDefault()"
                        autocomplete="off"
                      />

                      <div class="pk-giphy-picker-scroll mt-2">
                        <%= cond do %>
                          <% @ctx.giphy_results != [] -> %>
                            <div
                              class="grid gap-2"
                              role="listbox"
                              aria-label={gettext("GIF results")}
                              style="grid-template-columns: repeat(3, minmax(0, 1fr));"
                            >
                              <%= for gif <- @ctx.giphy_results do %>
                                <button
                                  type="button"
                                  role="option"
                                  aria-label={gettext("Select GIF %{id}", id: gif["id"])}
                                  phx-click="select_giphy"
                                  phx-value-id={gif["id"]}
                                  phx-target={@ctx.myself}
                                  class="border border-base-300 rounded hover:border-primary overflow-hidden bg-base-200"
                                >
                                  <img
                                    src={gif["preview_url"]}
                                    loading="lazy"
                                    alt=""
                                    class="w-full object-cover"
                                    style="height: 6rem;"
                                  />
                                </button>
                              <% end %>
                            </div>
                          <% String.trim(@ctx.giphy_query) == "" -> %>
                            <p class="text-xs text-base-content/60 text-center py-4">
                              {gettext("Type a search term to find GIFs.")}
                            </p>
                          <% true -> %>
                            <p class="text-xs text-base-content/60 text-center py-4">
                              {gettext("No results.")}
                            </p>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

            <% true -> %>
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="cancel_new_comment"
            phx-target={@ctx.myself}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Hide")}
          </button>
          <%!-- Without this a double-click on a slow link posted the same
               comment twice: two events queue, both carry the same text,
               attachments are consumed by the first and the second lands as
               a text-only twin. --%>
          <button
            type="submit"
            phx-disable-with={gettext("Posting…")}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> {@submit_label}
          </button>
        </div>
      </div>
    </.form>
    """
  end

  # The "Write comment" composer for one placement (:top or :bottom).
  # Renders the open form when this position is the one currently open
  # (`composer_open_at == position`) and no reply is in progress; the
  # "Write comment" button when closed; the sign-in notice (once, at the
  # primary position) when the viewer can't post. Driven entirely by the
  # parent's assigns, passed through as `ctx`, so events target the
  # parent LiveComponent (`ctx.myself`).
  attr(:ctx, :map, required: true)
  attr(:position, :atom, required: true)

  defp new_comment_composer(assigns) do
    # Top composer sits above the list (mb), bottom sits below it (mt).
    assigns =
      assign(assigns, :spacing, if(assigns.position == :top, do: "mb-6", else: "mt-6"))

    ~H"""
    <%= cond do %>
      <% not @ctx.can_post? -> %>
        <%= if @position == primary_composer_position(@ctx.composer_position) do %>
          <div class={[@spacing, "text-sm text-base-content/60"]}>
            {gettext("Sign in to post a comment.")}
          </div>
        <% end %>
      <% @ctx.composer_open_at == @position and is_nil(@ctx.reply_to) -> %>
        <div class={@spacing}>
          <.composer_form
            ctx={@ctx}
            editor_id={draft_editor_id(@ctx.id, @position)}
            suffix={@position}
            placeholder={gettext("Write a comment...")}
            submit_label={gettext("Post Comment")}
            with_extras
          />
        </div>
      <% is_nil(@ctx.reply_to) -> %>
        <div class={@spacing}>
          <button
            type="button"
            phx-click="open_composer"
            phx-value-position={@position}
            phx-target={@ctx.myself}
            class="btn btn-primary w-full sm:w-auto"
          >
            <.icon name="hero-pencil-square" class="w-5 h-5 mr-2" /> {gettext("Write comment")}
          </button>
        </div>
      <% true -> %>
    <% end %>
    """
  end

  # The single position that shows the "sign in to post" notice when the
  # viewer can't post — avoids rendering it twice for composer_position
  # :both. First present position wins.
  defp primary_composer_position(:bottom), do: :bottom
  defp primary_composer_position(_), do: :top

  defp project_voice_offered?(ctx) do
    case {ctx[:project_attribution], ctx[:current_user]} do
      {%{} = attribution, %{} = user} -> eligible_for_project_voice?(attribution, user)
      _ -> false
    end
  end

  # What gets frozen onto the row. The checkbox is INTENT; this is the
  # decision, made server-side at submit.
  #
  # Re-asking the host's `verify` at write is the point: the composer was
  # rendered at some earlier moment, and membership can be revoked in
  # between. Trusting the assign would mean a removed member could keep
  # speaking for the project by leaving a tab open.
  #
  # A refused claim quietly becomes a personal comment rather than an
  # error — the comment is still perfectly valid, and an error here would
  # also make the control a membership oracle.
  defp resolve_attribution(socket, params) do
    user = socket.assigns.current_user
    personal = %{mode: "personal", label: display_name(user)}

    with true <- params["post_as_project"] in ["true", "on", true],
         %{} = attribution <- socket.assigns[:project_attribution],
         true <- eligible_for_project_voice?(attribution, user) do
      %{
        mode: "project",
        label: attribution[:label],
        project_uuid: attribution[:project_uuid]
      }
    else
      _ -> personal
    end
  end

  defp eligible_for_project_voice?(%{verify: verify} = attribution, user)
       when is_function(verify, 1) do
    is_binary(attribution[:label]) and attribution[:label] != "" and verify.(user.uuid) == true
  end

  # No verifier supplied means the host cannot vouch for anyone, so nobody
  # speaks for the project. Fail closed.
  defp eligible_for_project_voice?(_attribution, _user), do: false

  # Who a comment is FROM, for the header.
  #
  # `author_display_name` is FROZEN on the row at write time. Re-deriving it
  # would rewrite history: a person who leaves, is renamed, or later fills in
  # a profile would have every comment they ever made silently re-signed —
  # and someone who posted under a project's name would be un-masked by an
  # unrelated membership change. Older rows have no frozen value, so they
  # fall back to the live chain.
  #
  # Never `user.email`, which is what this used to print, on public boards
  # included.
  defp author_name(%{author_display_name: name}) when is_binary(name) and name != "", do: name
  defp author_name(%{user: %User{} = user}), do: display_name(user)
  defp author_name(_), do: gettext("Unknown")

  # `User.display_name/1` landed in a core release NEWER than this module's
  # declared floor (`mix.exs` pins `~> 1.7.189`). Calling it unguarded meant a
  # host resolving core from Hex at that floor got UndefinedFunctionError on
  # the main comment-render path. Pinning the newer core is not an option
  # while it is unreleased, so the chain is reproduced here for older cores.
  #
  # The chain must stay in step with core's: name, then username, then the
  # LOCAL PART of the email — never the address itself, which is what this
  # module used to print next to every comment.
  defp display_name(user) do
    if function_exported?(User, :display_name, 1) do
      # `apply/3` on purpose: a direct call is resolved at compile time and
      # warns against the older core this module still declares as its
      # floor, which is exactly the version the guard exists for.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(User, :display_name, [user])
    else
      fallback_display_name(user)
    end
  end

  defp fallback_display_name(user) do
    [
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" "),
      Map.get(user, :username),
      user |> Map.get(:email) |> to_string() |> String.split("@") |> List.first()
    ]
    |> Enum.find_value("User", fn
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
    end)
  end

  defp leaf_available?, do: Code.ensure_loaded?(Leaf)

  # Site-wide default editor mode for every Leaf instance we render.
  # `PhoenixKit.Settings.get_editor_mode/0` only exists in newer core
  # builds, but our pin allows older ones — so probe for the function
  # before calling it (the `no_warn_undefined` above covers the compile
  # side). Leaf's `:mode` clauses have no catch-all, so a string setting
  # value or anything unrecognised is normalised here rather than blowing
  # up inside Leaf's update/2. Settings reads can also raise when no repo
  # is configured, same as `PhoenixKitComments.enabled?/0` — hence the
  # rescue.
  defp default_editor_mode do
    if Code.ensure_loaded?(PhoenixKit.Settings) and
         function_exported?(PhoenixKit.Settings, :get_editor_mode, 0) do
      __normalize_editor_mode__(PhoenixKit.Settings.get_editor_mode())
    else
      @default_editor_mode
    end
  rescue
    _ -> @default_editor_mode
  end

  @doc false
  # Public only so the mode contract can be pinned by a unit test.
  def __normalize_editor_mode__(mode) when mode in @leaf_editor_modes, do: mode

  def __normalize_editor_mode__(mode) when is_binary(mode) do
    Enum.find(@leaf_editor_modes, @default_editor_mode, &(to_string(&1) == mode))
  end

  def __normalize_editor_mode__(_mode), do: @default_editor_mode

  # Draft editor id is position-scoped (:top / :bottom) so a
  # composer_position: :both embed never mounts two Leaf editors under
  # the same DOM id. Only one position is open at a time, but the ids
  # still differ so morphdom can't confuse them.
  defp draft_editor_id(component_id, position),
    do: "pk-comments:#{component_id}:draft:#{position}"

  defp reply_editor_id(component_id, comment_uuid),
    do: "pk-comments:#{component_id}:reply:#{comment_uuid}"

  defp edit_editor_id(component_id, comment_uuid),
    do: "pk-comments:#{component_id}:edit:#{comment_uuid}"

  # Clear the Leaf editor that was just submitted. For a reply it's the
  # per-comment reply editor; for a new comment it's the draft editor at
  # whichever position was open (falls back to :top if unknown). No-op when
  # the plain-textarea fallback is in use (no Leaf editor to reset).
  defp reset_leaf_draft_editor(false, _component_id, _reply_to, _composer_open_at), do: :ok

  defp reset_leaf_draft_editor(true, component_id, reply_to, composer_open_at) do
    if leaf_available?() do
      editor_id =
        case reply_to do
          nil -> draft_editor_id(component_id, composer_open_at || :top)
          comment_uuid -> reply_editor_id(component_id, comment_uuid)
        end

      Phoenix.LiveView.send_update(Leaf,
        id: editor_id,
        action: :set_content,
        content: ""
      )
    end
  end
end
