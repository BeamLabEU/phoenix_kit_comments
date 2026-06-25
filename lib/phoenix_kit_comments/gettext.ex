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
  locale that core sets via `Gettext.put_locale/1`. Core stores the *resolved
  dialect* there (`PhoenixKit…DialectMapper`), not the base code — e.g. `en`
  becomes `en-US`, `de` becomes `de-DE`. So a new catalog must be named by the
  dialect code, otherwise Gettext won't find it and the UI falls back to the
  English source. `ru` and `et` work as plain base codes only because the mapper
  maps them to themselves; `de` would need `priv/gettext/de-DE/…`, not `de`.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_comments
end
