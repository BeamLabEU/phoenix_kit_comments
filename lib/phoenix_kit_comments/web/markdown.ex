defmodule PhoenixKitComments.Web.Markdown do
  @moduledoc """
  Shared markdown rendering for comment content.

  Comments are authored as markdown in the Leaf composer (which renders with
  MDEx); rendering with the same engine and `render` options on display keeps
  the two consistent. Output is sanitised by MDEx's allow-list for XSS
  protection. Used by both the public comments component and the admin
  moderation page so bold/italics/lists/etc. show formatted instead of raw.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders a comment's markdown content to sanitized HTML inside a `pk-comment-md`
  block. The `.pk-comment-md` class (styled by `comment_markdown_styles/1`)
  restores list/block spacing without depending on the `@tailwindcss/typography`
  (`prose`) plugin being present in the host — render `comment_markdown_styles`
  once on any page that uses this.

  Named `comment_markdown` (not `markdown`) to avoid clashing with core's
  `PhoenixKitWeb.Components.Core.Markdown.markdown/1`, which is imported wherever
  `use PhoenixKitWeb` is in play.
  """
  # `hardbreaks` matches what the Leaf composer shows while typing; `unsafe`
  # is what makes the sanitiser load-bearing rather than decorative.
  #
  # MDEx's default allow-list keeps `style` and `class` on `div`, `span`,
  # `code` and `pre`. Either lets a comment draw over the page: inline CSS
  # (`position:fixed; inset:0`) directly, and `class` through the page's own
  # stylesheet — the host's Tailwind and daisyUI, including classes this
  # module's templates compile (`toast toast-top`, `alert`, `btn`,
  # `fixed inset-0`). That is a fake "session expired" banner with a link
  # on every reader's page and on the moderation page, which renders the
  # same component. Comments need neither: Leaf writes no inline styles, and
  # the `language-*` class on a fenced block styles nothing here. (Only
  # `div` was stripped, and only of `style`.) `javascript:` inside `url()`
  # is not executed by current browsers; the overlay is the real reason.
  @stripped_attributes ["style", "class"]
  @render_opts [
    render: [hardbreaks: true, unsafe: true],
    sanitize:
      Keyword.put(
        MDEx.Document.default_sanitize_options(),
        :rm_tag_attributes,
        Map.new(~w(div span code pre), &{&1, @stripped_attributes})
      )
  ]

  attr(:content, :string, required: true, doc: "The markdown content to render")
  attr(:class, :string, default: "", doc: "Additional CSS classes")
  attr(:compact, :boolean, default: false, doc: "Use smaller (text-sm) text for previews")
  # No `sanitize` attr, deliberately. Comment bodies are written by whoever
  # can post, so there is no caller for whom skipping sanitisation would be
  # correct — and an opt-out on this component is one `sanitize={false}` away
  # from stored XSS on every reader of a thread.

  def comment_markdown(assigns) do
    assigns = assign(assigns, :html_content, render_markdown(assigns.content))

    ~H"""
    <div class={["pk-comment-md max-w-none", @compact && "text-sm", @class]}>
      {raw(@html_content)}
    </div>
    """
  end

  @doc """
  One-off `<style>` block with the `.pk-comment-md` rules. Render it ONCE per
  page that uses `comment_markdown/1` (Tailwind's preflight zeroes list/block
  margins; this restores them without the typography plugin). Bold/italic render
  via `<strong>`/`<em>` already.
  """
  def comment_markdown_styles(assigns) do
    ~H"""
    <style>
      .pk-comment-md p { margin: 0.5rem 0; }
      .pk-comment-md p:first-child { margin-top: 0; }
      .pk-comment-md p:last-child { margin-bottom: 0; }
      .pk-comment-md ul, .pk-comment-md ol { padding-left: 1.5rem; margin: 0.5rem 0; }
      .pk-comment-md ul { list-style: disc; }
      .pk-comment-md ul ul { list-style: circle; }
      .pk-comment-md ol { list-style: decimal; }
      .pk-comment-md li { margin: 0.125rem 0; }
      .pk-comment-md a { color: oklch(var(--p)); text-decoration: underline; }
      .pk-comment-md :is(h1, h2, h3, h4, h5, h6) { font-weight: 600; margin: 0.75rem 0 0.25rem; }
      .pk-comment-md blockquote { border-left: 3px solid oklch(var(--bc) / 0.2); padding-left: 0.75rem; margin: 0.5rem 0; opacity: 0.85; }
      .pk-comment-md code { background: oklch(var(--bc) / 0.1); padding: 0.1rem 0.3rem; border-radius: 0.25rem; font-size: 0.875em; }
      .pk-comment-md pre { background: oklch(var(--bc) / 0.08); overflow-x: auto; padding: 0.5rem 0.75rem; border-radius: 0.375rem; margin: 0.5rem 0; }
      .pk-comment-md pre code { background: none; padding: 0; font-size: inherit; }
    </style>
    """
  end

  @doc """
  Renders markdown to sanitised HTML (or escaped text on a parse error). Blank
  input returns an empty string.

  ## Why `sanitize:` and not a regex pass afterwards

  `unsafe: true` is what lets a comment contain real markdown-adjacent HTML,
  and it disables MDEx's own escaping — so everything downstream of it is the
  security boundary. That used to be a handful of regexes over the rendered
  string, which is a blocklist, and a blocklist over HTML loses:

    * `&lt;script&gt;alert(1)` with NO closing tag survived — the pattern required
      a matching `&lt;/script&gt;`.
    * `&lt;a href=javascript:alert(1)&gt;` survived — the pattern required the value
      to be quoted.

  Both were verified against the real renderer, and both execute for every
  reader of a thread and again in the admin moderation list, which renders the
  same component. MDEx's `:sanitize` is ammonia, an allow-list: unknown tags
  and every attribute outside the allowed set are dropped rather than matched
  against, and it rewrites `rel` on links for free. There is no opt-out.
  """
  def render_markdown(content) when content in [nil, ""], do: ""

  def render_markdown(content) when is_binary(content) do
    case MDEx.to_html(content, @render_opts) do
      {:ok, html} -> restrict_images(html)
      {:error, _reason} -> content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  def render_markdown(_other), do: ""

  # The sanitiser keeps `<img>` with any http(s) or relative `src`, so a
  # comment could embed a tracking pixel: every reader's browser, and every
  # moderator's, fetched it and handed the image's owner their IP address,
  # whenever the comment was on screen. Images from this site (a relative
  # path, or its own host) and from Giphy are shown; any other becomes a link
  # to it, so a reader decides whether to open it.
  #
  # Run on the SANITISED output, which is serialised canonically: every
  # attribute value double-quoted with `"` escaped inside it, so `[^"]*`
  # cannot run past the end of a value. The values are decoded and escaped
  # again before reuse rather than trusted to be safe as text.
  @img_tag ~r/<img((?:\s+[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:="[^"]*")?)*)\s*\/?>/
  @img_attr ~r/([a-zA-Z_:][-a-zA-Z0-9_:.]*)="([^"]*)"/

  defp restrict_images(html) do
    if String.contains?(html, "<img"),
      do: Regex.replace(@img_tag, html, fn tag, attrs -> shown_or_linked(tag, attrs) end),
      else: html
  end

  defp shown_or_linked(tag, attrs) do
    found =
      @img_attr
      |> Regex.scan(attrs, capture: :all_but_first)
      |> Map.new(fn [name, value] -> {String.downcase(name), decode_attribute(value)} end)

    case found["src"] do
      nil -> ""
      src -> if allowed_image?(src), do: tag, else: image_link(src, found["alt"])
    end
  end

  defp image_link(src, alt) do
    text = if is_binary(alt) and String.trim(alt) != "", do: alt, else: src

    ~s(<a href="#{escape(src)}" rel="noopener noreferrer nofollow">#{escape(text)}</a>)
  end

  defp allowed_image?(src) do
    case URI.parse(src) do
      # A relative path is this site's own ("//host/…" has a host).
      %URI{scheme: nil, host: nil} ->
        true

      %URI{host: host} when is_binary(host) ->
        PhoenixKitComments.giphy_url?(src) or own_host?(host)

      _ ->
        false
    end
  end

  # Asked only for an absolute, non-Giphy image: the site's base URL is a
  # settings read, which every other comment never needs.
  defp own_host?(host) do
    case URI.parse(Routes.base_url()) do
      %URI{host: own} when is_binary(own) -> String.downcase(own) == String.downcase(host)
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # The serialiser escapes `&`, `"` and U+00A0 in attribute values (and this
  # one `<` and `>` too); `&amp;` last, so `&amp;quot;` stays `&quot;`.
  defp decode_attribute(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", "\u00A0")
    |> String.replace("&amp;", "&")
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
