defmodule PhoenixKitComments.Integration.ConcurrentApprovalTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import PhoenixKitComments.DataCase, only: [user_fixture: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitComments.Comment
  alias PhoenixKitComments.Test.Repo

  @moduletag :integration

  defmodule Handler do
    @moduledoc false
    @behaviour PhoenixKitComments.ResourceHandler

    @impl true
    def on_comment_published(_type, _resource, comment),
      do: send(:persistent_term.get({__MODULE__, :pid}), {:published, comment.uuid})
  end

  test "two moderators on separate connections notify once" do
    previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)

    Application.put_env(:phoenix_kit, :comment_resource_handlers, %{"concurrent_probe" => Handler})

    :persistent_term.put({Handler, :pid}, self())

    on_exit(fn ->
      :persistent_term.erase({Handler, :pid})

      if previous,
        do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
        else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
    end)

    # Real commits and independent connections are needed to exercise the lock.
    # Sharing a sandbox transaction would serialize both calls on one connection.
    {author, comment} =
      Sandbox.unboxed_run(Repo, fn ->
        author = user_fixture()

        comment =
          %Comment{}
          |> Comment.changeset(%{
            resource_type: "concurrent_probe",
            resource_uuid: Ecto.UUID.generate(),
            user_uuid: author.uuid,
            content: "held for moderation",
            status: "pending"
          })
          |> Repo.insert!()

        {author, comment}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(c in Comment, where: c.uuid == ^comment.uuid))
        Repo.delete_all(from(u in User, where: u.uuid == ^author.uuid))
      end)
    end)

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            :approve ->
              Sandbox.unboxed_run(Repo, fn ->
                PhoenixKitComments.approve_comment(comment, log: false, broadcast: false)
              end)
          end
        end)
      end

    try do
      Enum.each(tasks, &send(&1.pid, :approve))

      for task <- tasks do
        assert {:ok, %Comment{status: "published"}} = Task.await(task)
      end

      assert_received {:published, _}
      refute_received {:published, _}
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end
end
