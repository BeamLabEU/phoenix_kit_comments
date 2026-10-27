defmodule PhoenixKitComments.ResourceHandlerTest do
  @moduledoc """
  The resource-handler contract.

  Dispatch is by `function_exported?/3` and always will be — a handler is
  named in host config, may live in another application, and may legitimately
  implement none of these. The cost of that is a callback this package never
  finds being indistinguishable from one the host chose not to write: misname
  it, or take the wrong number of arguments, and nothing happens anywhere.

  The behaviour exists to turn that into a compile warning. Which makes the
  behaviour itself the thing that can now drift: a callback added to the
  dispatcher and not the contract is the same silent failure wearing a
  different hat, so that pairing is what these check.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitComments.ResourceHandler

  @source "lib/phoenix_kit_comments.ex"

  describe "the contract" do
    test "declares every callback optional" do
      # A handler that cares about one event should be a two-line module. If
      # any of these were required, adopting the behaviour would mean writing
      # five stubs, and nobody would adopt it.
      optional = ResourceHandler.behaviour_info(:optional_callbacks) |> Enum.sort()

      assert optional == ResourceHandler.callbacks()
    end

    test "every comment-event callback takes three arguments" do
      # The dispatcher asks `function_exported?(mod, callback, 3)` and applies
      # three arguments. An event callback declared at any other arity would be
      # declared and never called.
      #
      # The lookups (`resolve_comment_resources/1`, `moderatable_resources/2`)
      # are deliberately excluded rather than the contract being assumed
      # uniform: each is a question a named caller asks directly, not
      # something `notify_resource_handler/4` fires, and each answers at its
      # own arity.
      for {name, arity} <- ResourceHandler.event_callbacks() do
        assert arity == 3, "#{name}/#{arity} is declared but the dispatcher only calls arity 3"
      end
    end

    test "the resource lookup is still part of the contract" do
      # It predates the event callbacks and is the one the renderer depends on
      # for titles and deep links. A rewrite of this contract that declares
      # only the six `on_comment_*` events silently drops it: hosts that
      # implement it get "@impl true but the behaviour does not specify such
      # callback", and the RAW-path rule documented against it loses its home.
      assert {:resolve_comment_resources, 1} in ResourceHandler.callbacks()
    end
  end

  describe "the lookups" do
    test "every named lookup is a declared callback" do
      # `event_callbacks/0` is defined as everything that is not a lookup, so
      # the only way the two lists can drift is a lookup named here that the
      # behaviour no longer declares — a host implementing it would get
      # "@impl true but the behaviour does not specify such callback".
      for lookup <- ResourceHandler.lookup_callbacks() do
        assert lookup in ResourceHandler.callbacks(), "#{inspect(lookup)} is not declared"
      end
    end

    test "the moderation scope asks moderatable_resources/2 at the declared arity" do
      # `resolve_comment_resources/1` is asked by core's ResourceLinks, outside
      # this repo. `moderatable_resources/2` is asked here, so its caller is
      # checkable: a rename on either side, or a call at another arity, would
      # leave every scoped moderator with an empty page and no error.
      source = File.read!(@source)

      assert {:moderatable_resources, 2} in ResourceHandler.callbacks()
      assert source =~ ~r/function_exported\?\(\s*\w+,\s*:moderatable_resources,\s*2\s*\)/
      assert source =~ ~r/\.moderatable_resources\(\s*\w+,\s*\w+\s*\)/
    end
  end

  describe "contract vs dispatcher" do
    test "every callback the dispatcher invokes is declared" do
      # The dispatcher names its callbacks in two places: directly at the
      # create/delete call sites, and through `reaction_callback/1`. Read them
      # out of the source rather than restating them, so adding a seventh
      # event without declaring it fails here.
      source = File.read!(@source)

      dispatched =
        Regex.scan(~r/:(on_comment_[a-z_]+)/, source)
        |> Enum.map(fn [_, name] -> String.to_atom(name) end)
        |> Enum.uniq()
        |> Enum.sort()

      declared = ResourceHandler.event_callbacks() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert dispatched == declared,
             """
             The dispatcher and the behaviour disagree.

               only dispatched: #{inspect(dispatched -- declared)}
               only declared:   #{inspect(declared -- dispatched)}

             A callback the dispatcher invokes but the behaviour does not
             declare gets no compile check, which is the failure this contract
             exists to prevent. One the behaviour declares but nothing invokes
             is a promise to a host that will never be kept.
             """
    end
  end

  describe "adopting it" do
    defmodule PartialHandler do
      @moduledoc false
      @behaviour PhoenixKitComments.ResourceHandler

      @impl true
      def on_comment_created(_type, _uuid, _comment), do: :handled
    end

    test "a handler may implement just one callback" do
      # Compiling this module at all is most of the test: if the callbacks
      # were not optional, `@behaviour` here would warn about five missing
      # implementations.
      assert PartialHandler.on_comment_created("post", "uuid", %{}) == :handled
      refute function_exported?(PartialHandler, :on_comment_deleted, 3)
    end

    test "the dispatcher's guard still governs what runs" do
      # Adopting the behaviour changes nothing at runtime — the guard is what
      # decides, exactly as it did before.
      assert function_exported?(PartialHandler, :on_comment_created, 3)
    end
  end
end
