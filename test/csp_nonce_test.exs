defmodule PhoenixKitComments.CSPNonceTest do
  @moduledoc """
  `PhoenixKitComments.Web.CSP.nonce/1` on both kinds of core: one that has
  `PhoenixKitWeb.CSP` (the nonce of the page reaches the module's `<style>` tags) and one that
  does not (no attribute, as before). Which half runs depends on the core the suite is
  compiled against: the Hex pin, or a local checkout through `PHOENIX_KIT_PATH`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitComments.Web.CSP
  alias PhoenixKitComments.Web.Markdown

  @compile {:no_warn_undefined, [PhoenixKitWeb.CSP]}
  @core PhoenixKitWeb.CSP
  @core_has_nonces Code.ensure_loaded?(@core) and function_exported?(@core, :nonce, 1)

  test "no nonce was set: nil, and the style tag has no nonce attribute" do
    assert CSP.nonce(:style) == nil
    assert CSP.nonce(:script) == nil

    html = render_component(&Markdown.comment_markdown_styles/1, %{})
    assert html =~ "<style>"
    refute html =~ "nonce"
  end

  if @core_has_nonces do
    test "the page's nonce, as core restores it for a LiveView, is on the style tag" do
      session = %{"phoenix_kit_csp_nonces" => %{"style" => "st-1", "script" => "sc-1"}}

      {:cont, _socket} =
        PhoenixKitWeb.CSP.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})

      assert CSP.nonce(:style) == "st-1"
      assert CSP.nonce(:script) == "sc-1"

      html = render_component(&Markdown.comment_markdown_styles/1, %{})
      assert html =~ ~s(<style nonce="st-1">)
    end
  else
    test "a core without PhoenixKitWeb.CSP: nothing to ask, nothing rendered" do
      refute Code.ensure_loaded?(@core) and function_exported?(@core, :nonce, 1)
    end
  end
end
