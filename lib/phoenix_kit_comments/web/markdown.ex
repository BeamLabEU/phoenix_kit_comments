defmodule PhoenixKitComments.Web.Markdown do
  @moduledoc """
  Shared markdown rendering for comment content.

  Comments are authored as markdown in the Leaf composer (which renders with
  MDEx); rendering with the same engine and `render` options on display keeps
  the two consistent. Output passes through core's `HtmlSanitizer` for XSS
  protection. Used by both the public comments component and the admin
  moderation page so bold/italics/lists/etc. show formatted instead of raw.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias PhoenixKit.Utils.HtmlSanitizer

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
  attr(:content, :string, required: true, doc: "The markdown content to render")
  attr(:class, :string, default: "", doc: "Additional CSS classes")
  attr(:compact, :boolean, default: false, doc: "Use smaller (text-sm) text for previews")
  attr(:sanitize, :boolean, default: true, doc: "Enable HTML sanitization")

  def comment_markdown(assigns) do
    assigns = assign(assigns, :html_content, render_markdown(assigns.content, assigns.sanitize))

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
  Renders markdown to sanitized HTML (or escaped text on a parse error). Blank
  input returns an empty string. Uses the same MDEx options as the Leaf composer
  (`hardbreaks`, `unsafe`) so display matches what was typed.
  """
  def render_markdown(content, sanitize \\ true)

  def render_markdown(content, _sanitize) when content in [nil, ""], do: ""

  def render_markdown(content, sanitize) when is_binary(content) do
    case MDEx.to_html(content, render: [hardbreaks: true, unsafe: true]) do
      {:ok, html} -> if sanitize, do: HtmlSanitizer.sanitize(html), else: html
      {:error, _reason} -> content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  def render_markdown(_other, _sanitize), do: ""
end
