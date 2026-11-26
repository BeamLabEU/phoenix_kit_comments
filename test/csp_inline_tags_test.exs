defmodule PhoenixKitComments.CSPInlineTagsTest do
  @moduledoc """
  The component and the admin pages of this module work under a host Content-Security-Policy
  that allows inline code by nonce only (`script-src 'self' 'nonce-…'`): every inline
  `<style>` / `<script>` carries the nonce (`PhoenixKitComments.Web.CSP.nonce/1`), and there
  is no inline event handler (no nonce can cover an attribute; `data-pkc-*` attributes and
  the listeners in `phoenix_kit_comments.js` do that work).

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  @bundle "priv/static/assets/phoenix_kit_comments.js"

  # No exemptions: nothing this module renders is cached or the same for everyone.
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (feature-detect `PhoenixKitWeb.CSP.nonce/1`, " <>
             "see AGENTS.md):\n" <> Enum.join(offenders, "\n")
  end

  test "the scan sees the tags there are, with their nonce" do
    for path <- [
          "lib/phoenix_kit_comments/web/comments_component.html.heex",
          "lib/phoenix_kit_comments/web/markdown.ex"
        ] do
      assert [{opening, _line}] = tag_openings(path)
      assert opening =~ "<style nonce={PhoenixKitComments.Web.CSP.nonce(:style)}>"
    end
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written, a literal attribute
  # the browser cannot match.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKitComments.Web.CSP",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, a hook, or a " <>
             "`data-pkc-*` attribute handled in phoenix_kit_comments.js):\n" <>
             Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button data-pkc-blur phx-click="go">) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  test "the bundle builds no markup with an inline event handler" do
    offenders =
      for {line, number} <- bundle_lines(),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/javascript:/i,
          do: "#{@bundle}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # A `<style>` / `<script>` the bundle creates is checked against the page's policy like any
  # other: it is stamped with the page's nonce (core's `PhoenixKitInternals.adoptStyle`, when
  # there) before it is inserted, and never written as a string for `innerHTML`. There is none
  # today. No `eval` either: `script-src` without 'unsafe-eval' blocks it.
  test "the bundle creates no unstamped <style>/<script>, and evaluates no strings" do
    lines = bundle_lines()

    offenders =
      for {{line, number}, index} <- Enum.with_index(lines),
          next = lines |> Enum.slice(index + 1, 4) |> Enum.map(&elem(&1, 0)),
          problem = bundle_problem(line, next),
          do: "#{@bundle}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp bundle_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(["'](?:style|script)["']\)/ and
          not Enum.any?(next_lines, &(&1 =~ "adoptStyle")) ->
        "creates a <style>/<script> that is not stamped in the next lines"

      line =~ ~r/["'`]<(?:style|script)\b/ ->
        "builds a <style>/<script> tag as a string"

      line =~ ~r/\beval\(|new Function\(/ ->
        "evaluates a string"

      true ->
        nil
    end
  end

  # The bundle's lines without its comment lines.
  defp bundle_lines do
    @bundle
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> line =~ ~r{^\s*(//|\*)} end)
  end

  # The attributes that replaced the inline handlers are only as good as the listener behind
  # them: each one the markup uses is handled in the bundle, and the other way round.
  test "every data-pkc-* attribute in the markup has its listener in the bundle" do
    used =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          [name] <- Regex.scan(~r/data-pkc-[a-z-]+/, File.read!(path)),
          uniq: true,
          do: name

    handled =
      for {line, _} <- bundle_lines(),
          [name] <- Regex.scan(~r/data-pkc-[a-z-]+/, line),
          uniq: true,
          do: name

    assert Enum.sort(used) == ["data-pkc-blur", "data-pkc-no-enter"]
    assert Enum.sort(handled) == Enum.sort(used)
  end

  test "the bundle is the only JavaScript the module ships" do
    assert Path.wildcard("{lib,priv}/**/*.{js,ts}") == [@bundle]
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
