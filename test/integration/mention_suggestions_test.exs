defmodule PhoenixKitComments.Integration.MentionSuggestionsTest do
  @moduledoc """
  The rich composer's `@` typeahead (a host's report, 2026-11-18: in the
  Leaf composer `@` showed no list and a typed name stayed text): what the
  component answers the editor, the host's people first, and the host's
  warning for a person who will not hear of the comment.
  """

  use PhoenixKitComments.DataCase, async: false

  alias PhoenixKitComments.Web.CommentsComponent

  setup do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("mentions_enabled", true)
    :ok
  end

  test "the host's people come first, in its order, then everyone else, each once" do
    viewer = user_fixture()
    first = user_fixture(%{username: "zed_first"})

    rows =
      CommentsComponent.mention_suggestions(
        %{
          current_user: viewer,
          pk_scope: nil,
          mention_people: [%{uuid: first.uuid, title: "Zed First", subtitle: "On this task"}]
        },
        "@",
        ""
      )

    assert [%{label: "Zed First", sublabel: "On this task", value: value} | rest] = rows
    assert value == "@[user:#{first.uuid}|Zed First]"

    # The rest come from core's search (its own rules decide who is
    # offered); the host's person is never repeated among them.
    values = Enum.map(rest, & &1.value)
    refute Enum.any?(values, &String.contains?(&1, first.uuid))
  end

  test "a typed query narrows the host's people too" do
    viewer = user_fixture()
    anna = user_fixture()

    people = [%{uuid: anna.uuid, title: "Anna Kask", subtitle: nil}]

    assert [%{label: "Anna Kask"} | _] =
             CommentsComponent.mention_suggestions(
               %{current_user: viewer, pk_scope: nil, mention_people: people},
               "@",
               "kas"
             )

    refute Enum.any?(
             CommentsComponent.mention_suggestions(
               %{current_user: viewer, pk_scope: nil, mention_people: people},
               "@",
               "nobody-like-this"
             ),
             &(&1.label == "Anna Kask")
           )
  end

  test "an unknown trigger answers nothing" do
    assert CommentsComponent.mention_suggestions(%{}, "/", "x") == []
  end
end
