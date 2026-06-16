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
  Renders a comment's markdown content to sanitized HTML inside a `prose` block.

  Named `comment_markdown` (not `markdown`) to avoid clashing with core's
  `PhoenixKitWeb.Components.Core.Markdown.markdown/1`, which is imported wherever
  `use PhoenixKitWeb` is in play.
  """
  attr(:content, :string, required: true, doc: "The markdown content to render")
  attr(:class, :string, default: "", doc: "Additional CSS classes (merged onto the prose block)")
  attr(:compact, :boolean, default: false, doc: "Use compact (prose-sm) styling for previews")
  attr(:sanitize, :boolean, default: true, doc: "Enable HTML sanitization")

  def comment_markdown(assigns) do
    assigns = assign(assigns, :html_content, render_markdown(assigns.content, assigns.sanitize))

    ~H"""
    <div class={[if(@compact, do: "prose prose-sm", else: "prose"), "max-w-none", @class]}>
      {raw(@html_content)}
    </div>
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
