defmodule PhoenixKitComments.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the inline `<style>` tags this module renders.

      <style nonce={PhoenixKitComments.Web.CSP.nonce(:style)}>

  The nonce is core's (`PhoenixKitWeb.CSP`), which a core older than the one that introduced
  it does not have: there this answers `nil`, and `nonce={nil}` renders no attribute, as
  before. Inline event handlers cannot take a nonce at all; `phoenix_kit_comments.js`
  ("DECLARATIVE HANDLERS") does their work. `test/csp_inline_tags_test.exs` enforces both.
  """

  @core PhoenixKitWeb.CSP

  @doc """
  The nonce of the current page for `kind`, or `nil` when the host set none or core has no
  nonce support.
  """
  @spec nonce(:script | :style) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    case core(:nonce, [kind], nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # The one call into core: `apply/3`, because the core floor has no such module and a direct
  # call would not pass the compiler or dialyzer there.
  defp core(function, args, default) do
    if Code.ensure_loaded?(@core) and function_exported?(@core, function, length(args)) do
      apply(@core, function, args)
    else
      default
    end
  end
end
