defmodule PhoenixKitComments.JsHooksTest do
  @moduledoc """
  Runs the JS hooks' own tests (`test/js/*.cjs`, `node --test`) as part of
  `mix test`, so the gate covers the bundle too.

  `priv/static/assets/phoenix_kit_comments.js` is hand-written and ships as
  it is — no build step, no bundler — and its tests used to run only when
  someone remembered the command in the README. Skipped where node is not
  installed.
  """
  use ExUnit.Case, async: true

  @node System.find_executable("node")
  @root Path.expand("..", __DIR__)
  @tests Path.wildcard(Path.join(@root, "test/js/*.cjs"))

  @tag skip: if(@node, do: false, else: "node is not installed")
  test "the JS hooks' tests pass" do
    refute Enum.empty?(@tests), "no test/js/*.cjs files found"

    {output, status} =
      System.cmd(@node, ["--test" | @tests], cd: @root, stderr_to_stdout: true)

    assert status == 0, output
  end
end
