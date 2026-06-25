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
  """
  use Gettext.Backend, otp_app: :phoenix_kit_comments
end
