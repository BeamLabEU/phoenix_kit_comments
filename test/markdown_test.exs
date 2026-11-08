defmodule PhoenixKitComments.Web.MarkdownTest do
  @moduledoc """
  Comment bodies are rendered with `unsafe: true` so that markdown-adjacent
  HTML works, which makes whatever runs afterwards the security boundary.

  It used to be a handful of regexes over the rendered string. A blocklist
  over HTML loses, and this one lost in two ways that a reader of the code
  would not spot: the `<script>` pattern required a CLOSING tag, and the
  `javascript:` patterns required the attribute value to be QUOTED. Both
  payloads below executed for every reader of a thread, and again in the
  admin moderation list, which renders the same component.

  These run against the real renderer, not a stub.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitComments.Web.Markdown

  @exploits [
    {"unclosed script tag", "<script>alert(document.domain)"},
    {"unquoted javascript: href", "<a href=javascript:alert(document.domain)>click me</a>"},
    {"entity-encoded javascript:", "<a href=\"javas&#99;ript:alert(1)\">x</a>"},
    {"img onerror", "<img src=x onerror=alert(1)>"},
    {"closed script tag", "<script>alert(1)</script>"},
    {"svg-wrapped script", "<svg><script>alert(1)</script></svg>"},
    {"iframe", "<iframe src=https://evil.example></iframe>"},
    {"onload on body", "<body onload=alert(1)>"},
    {"style expression", "<div style=\"background:url(javascript:alert(1))\">x</div>"},
    {"nested obfuscation", "<scr<script>ipt>alert(1)</scr</script>ipt>"}
  ]

  describe "render_markdown/1 strips executable content" do
    for {name, payload} <- @exploits do
      test "neutralises: #{name}" do
        html = Markdown.render_markdown(unquote(payload))

        refute html =~ "<script", "a script tag survived"
        refute html =~ "javascript:", "a javascript: URL survived"
        refute html =~ "onerror", "an inline event handler survived"
        refute html =~ "onload", "an inline event handler survived"
        refute html =~ "<iframe", "an iframe survived"
      end
    end
  end

  # MDEx's allow-list keeps `style` and `class` on these four. Inline CSS
  # positions an element over the page directly; a class does it through the
  # host's own stylesheet (`fixed inset-0`, daisyUI's `toast`/`alert`/`btn`).
  # Either draws a fake banner over every reader's page and over the
  # moderation page, which renders the same component.
  describe "render_markdown/1 lets no comment restyle the page" do
    for tag <- ~w(div span code pre) do
      test "#{tag}: no style" do
        html =
          Markdown.render_markdown(
            ~s(<#{unquote(tag)} style="position:fixed;inset:0;z-index:9999">x</#{unquote(tag)}>)
          )

        assert html =~ "x"
        refute html =~ "style="
        refute html =~ "position:fixed"
      end

      test "#{tag}: no class" do
        html =
          Markdown.render_markdown(
            ~s(<#{unquote(tag)} class="toast toast-top fixed inset-0 z-50">x</#{unquote(tag)}>)
          )

        assert html =~ "x"
        refute html =~ "class="
        refute html =~ "toast"
      end
    end

    test "a fenced code block still renders as code" do
      html = Markdown.render_markdown("```elixir\ndef a, do: 1\n```")

      assert html =~ "<pre>"
      assert html =~ "<code>"
      assert html =~ "def a, do: 1"
    end
  end

  describe "render_markdown/1 keeps what comments are for" do
    test "ordinary markdown still renders" do
      html = Markdown.render_markdown("**bold** _em_ `code`\n\n- a\n- b")

      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>em</em>"
      assert html =~ "<code>code</code>"
      assert html =~ "<li>a</li>"
    end

    test "links survive and carry rel" do
      html = Markdown.render_markdown("[link](https://example.com)")

      assert html =~ ~s(href="https://example.com")
      # The allow-list adds this for free; the regex pass never did.
      assert html =~ "noopener"
    end

    test "blank and non-binary input are empty, not a crash" do
      assert Markdown.render_markdown(nil) == ""
      assert Markdown.render_markdown("") == ""
      assert Markdown.render_markdown(%{}) == ""
      assert Markdown.render_markdown(123) == ""
    end

    test "there is no way to ask for unsanitised output" do
      # `render_markdown/2` used to take a `sanitize` flag, and
      # `comment_markdown/1` exposed it as an attr defaulting to true. A
      # single `sanitize={false}` anywhere would have been stored XSS on
      # every reader of a thread, so the escape hatch is gone rather than
      # merely defaulted safely.
      refute function_exported?(Markdown, :render_markdown, 2)
    end
  end
end
