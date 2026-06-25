[
  # Gettext compiles the PO `Plural-Forms` header into a literal
  # `%Expo.PluralForms{}` (an opaque struct) and hands it to
  # `Gettext.Plural.plural/2` from inside the generated `PhoenixKitComments.Gettext`
  # backend code. Dialyzer flags passing the opaque term outside `Expo`, but the
  # value is correct at runtime (the suite exercises it). Surfaced by the `ru`
  # catalog's custom `nplurals=3` plural AST.
  {"lib/phoenix_kit_comments/gettext.ex", :call_without_opaque}
]
