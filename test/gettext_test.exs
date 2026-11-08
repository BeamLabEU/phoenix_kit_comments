defmodule PhoenixKitComments.GettextTest do
  @moduledoc """
  The translation catalogs are complete and well-formed.

  A msgid added to the code reaches every catalog through
  `mix gettext.extract --merge`, but with an empty msgstr, which Gettext
  answers with the English source: the page silently switches language
  half-way. A reworded msgid comes back `fuzzy`, which Gettext ignores the
  same way. These tests turn both into a failure, and check each translation
  keeps the source's placeholders (a missing `%{count}` prints nothing; a
  renamed one raises at render) and has the locale's number of plural forms.
  """
  use ExUnit.Case, async: true

  alias Expo.Message

  @root Path.expand("../priv/gettext", __DIR__)
  @locales ~w(de en es et fr it ru zh)
  # The source language: an empty msgstr is the msgid itself, as intended.
  @source_locale "en"

  defp pot, do: Expo.PO.parse_file!(Path.join(@root, "default.pot"))

  defp po(locale),
    do: Expo.PO.parse_file!(Path.join([@root, locale, "LC_MESSAGES", "default.po"]))

  defp text(iodata), do: IO.iodata_to_binary(iodata)

  defp placeholders(string),
    do:
      ~r/%\{(\w+)\}/
      |> Regex.scan(string, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

  defp nplurals(%Expo.Messages{headers: headers}) do
    [_, n] = Regex.run(~r/nplurals\s*=\s*(\d+)/, Enum.join(headers))
    String.to_integer(n)
  end

  defp translations(%Message.Singular{msgstr: msgstr}), do: [text(msgstr)]

  defp translations(%Message.Plural{msgstr: msgstr}),
    do: msgstr |> Enum.sort() |> Enum.map(fn {_index, value} -> text(value) end)

  defp source_placeholders(%Message.Singular{msgid: id}), do: placeholders(text(id))

  # A plural's forms may each use the plural msgid's placeholders.
  defp source_placeholders(%Message.Plural{msgid: id, msgid_plural: plural}),
    do: MapSet.union(placeholders(text(id)), placeholders(text(plural)))

  test "every locale the module supports has a catalog, and no other" do
    found =
      @root
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(@root, &1)))
      |> Enum.sort()

    assert found == @locales
  end

  for locale <- @locales do
    @locale locale

    test "#{locale}: carries every msgid of the template, and nothing else" do
      keys = fn messages -> messages.messages |> Enum.map(&Message.key/1) |> MapSet.new() end
      template = keys.(pot())
      catalog = keys.(po(@locale))

      assert MapSet.difference(template, catalog) == MapSet.new(),
             "run `mix gettext.extract --merge`"

      assert MapSet.difference(catalog, template) == MapSet.new(),
             "obsolete entries; run `mix gettext.extract --merge`"
    end

    test "#{locale}: no fuzzy entry" do
      fuzzy =
        for message <- po(@locale).messages,
            "fuzzy" in List.flatten(message.flags),
            do: text(message.msgid)

      assert fuzzy == []
    end

    test "#{locale}: plural entries have the locale's number of forms" do
      catalog = po(@locale)
      n = nplurals(catalog)

      wrong =
        for %Message.Plural{} = message <- catalog.messages,
            map_size(message.msgstr) != n,
            do: text(message.msgid)

      assert wrong == []
    end

    unless locale == @source_locale do
      test "#{locale}: every entry is translated and keeps its placeholders" do
        problems =
          for message <- po(@locale).messages,
              value <- translations(message),
              problem = problem(message, value),
              do: {text(message.msgid), problem}

        assert problems == []
      end
    end
  end

  defp problem(_message, ""), do: :untranslated

  # Every placeholder kept, none invented. Even a plural's first form keeps
  # `%{count}`: in Russian it is also the form for 21, 31, …
  defp problem(message, value) do
    expected = source_placeholders(message)
    got = placeholders(value)

    if got == expected,
      do: nil,
      else: {:placeholders, expected: MapSet.to_list(expected), got: MapSet.to_list(got)}
  end

  test "labels core translates at render time are in the template" do
    msgids = pot().messages |> Enum.map(&text(&1.msgid)) |> MapSet.new()

    meta = PhoenixKitComments.permission_metadata()

    labels =
      [meta.label | Enum.map(meta.sub_permissions, & &1.label)] ++
        Enum.map(
          PhoenixKitComments.admin_tabs() ++ PhoenixKitComments.settings_tabs(),
          & &1.label
        )

    assert meta.gettext_backend == PhoenixKitComments.Gettext
    assert Enum.reject(labels, &MapSet.member?(msgids, &1)) == []
  end
end
