defmodule PhoenixKitComments.Web.MentionUnescapeTest do
  @moduledoc """
  Leaf's visual mode writes markdown back from HTML and escapes a mention
  token's `[` (and `_` in its type). The component undoes that for complete
  tokens only, so a picked mention stays a mention.
  """
  use ExUnit.Case, async: true

  import PhoenixKitComments.Web.CommentsComponent, only: [unescape_mention_tokens: 1]

  @uuid "01a0306e-577c-790e-971a-4e8dee4d3200"

  test "an escaped person token is a token again" do
    assert unescape_mention_tokens("Hi @\\[user:#{@uuid}|Ada Lovelace] there") ==
             "Hi @[user:#{@uuid}|Ada Lovelace] there"
  end

  test "an escaped record token, with an underscore in its type and label" do
    assert unescape_mention_tokens("See #\\[project\\_task:#{@uuid}|Q3\\_launch]") ==
             "See #[project_task:#{@uuid}|Q3_launch]"
  end

  test "a token already intact is left as it is" do
    text = "Hi @[user:#{@uuid}|Ada]"
    assert unescape_mention_tokens(text) == text
  end

  test "anything short of a complete token keeps its escapes" do
    for text <- [
          "@\\[user:not-a-uuid|Ada]",
          "@\\[user:#{@uuid}]",
          "@\\[user:#{@uuid}|Ada",
          "a \\[link\\] and @\\[note]"
        ] do
      assert unescape_mention_tokens(text) == text
    end
  end

  test "an escaped trigger (a token meant to stay text) is left alone" do
    text = "\\@\\[user:#{@uuid}|Ada]"
    assert unescape_mention_tokens(text) == text
  end

  test "nil is empty" do
    assert unescape_mention_tokens(nil) == ""
  end
end
