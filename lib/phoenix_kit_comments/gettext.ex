defmodule PhoenixKitComments.Gettext do
  @moduledoc """
  Gettext backend for the comments module's own translations.

  The module's LiveView / LiveComponent `use PhoenixKitWeb`, which binds the
  `gettext/1`, `ngettext/3`, … macros to core's `PhoenixKitWeb.Gettext`. Those
  modules additionally `use Gettext, backend: PhoenixKitComments.Gettext`, which
  rebinds the macros to this backend, so the comments strings resolve against
  **this** module's catalogs (`priv/gettext`) instead of core's. That keeps the
  comments translations self-contained in this package — extract + translate
  with the module's own `mix gettext.extract` / `mix gettext.merge`.

  ## Naming new locale catalogs

  This backend has no per-backend locale wiring; it reads the process-global
  locale that core sets via `Gettext.put_locale/1`. Core (since 2.44) sets it
  to `PhoenixKit.Utils.RecipientLocale.gettext_locale/1` of the visitor's
  dialect: the base code for every language core's own catalog has
  (`de-DE` → `de`, `es-ES` → `es`) and the base code for the rest too
  (`zh-CN` → `zh`). So a catalog is named by the base code
  (`priv/gettext/de/…`); one named `de-DE` would never be read. Create one
  with `mix gettext.merge priv/gettext --locale <code>`.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_comments
end
