defmodule PhoenixKitComments.Activity do
  @moduledoc """
  Activity-log wrapper for the Comments module.

  The module had none. Eleven mutating functions — including the moderation
  ones, `approve_comment/1`, `hide_comment/1` and `bulk_update_status/2` —
  wrote nothing to the audit trail, so "who hid this comment, and when"
  had no answer anywhere in the system.

  ## What is safe to record

  Comment bodies are free text a user typed, so they never go in metadata.
  Neither do email addresses. What goes in is the shape of the action:
  status, resource type, counts, and uuids that resolve to a record for
  anyone entitled to look it up.

  Logging never crashes the caller: core's `PhoenixKit.Activity.log/3`
  returns a missing activity table (a host that has not migrated) or a
  dead pool as a logged `{:error, _}` — an audit line is not worth losing
  the write it describes.
  """

  @module "comments"

  @doc """
  Logs one action under the `"comments"` module key. Options as
  `PhoenixKit.Activity.log/3`.
  """
  @spec log(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def log(action, opts \\ []) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log(@module, action, opts)

  @doc """
  Pipe-step for `{:ok, %Comment{}}` repo results.

  Passes `{:error, _}` straight through, so a failed write logs nothing —
  which is the point: the log should describe what happened, not what was
  attempted.
  """
  @spec log_comment({:ok, struct()} | {:error, term()}, binary(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def log_comment(result, action, opts \\ [])

  def log_comment({:ok, comment} = result, action, opts) do
    # `log: false` lets a caller that wraps another mutation keep one line
    # in the trail instead of two — `delete_comment/2` goes through
    # `update_comment/3`, and "updated" then "deleted" reads like two
    # separate acts.
    if Keyword.get(opts, :log, true) do
      log(
        action,
        opts
        |> Keyword.drop([:log])
        |> then(
          &Keyword.merge(
            [
              resource_type: "comment",
              resource_uuid: comment.uuid,
              target_uuid: comment.user_uuid,
              metadata: comment_metadata(comment)
            ],
            &1
          )
        )
      )
    end

    result
  end

  def log_comment(result, _action, _opts), do: result

  # Never the body, never an email. Everything here is either an enum, a
  # count or a uuid.
  defp comment_metadata(comment) do
    %{
      "status" => comment.status,
      "resource_type" => comment.resource_type,
      "resource_uuid" => comment.resource_uuid,
      "depth" => comment.depth,
      "is_reply" => not is_nil(comment.parent_uuid)
    }
  end
end
