defmodule Termite.SSH.Session do
  @moduledoc """
  Per-connection context passed to a `Termite.SSH` session entrypoint.

  Sessions are created by `Termite.SSH`; applications should treat the struct
  as read-only. Use `Termite.SSH.terminal/1` to attach a terminal and
  `Termite.SSH.disconnect/1` to close the SSH channel.
  """

  defstruct [:id, :channel_pid, :username, :disconnect]

  @typedoc "An SSH-backed Termite session."
  @type t :: %__MODULE__{
          id: reference(),
          channel_pid: pid(),
          username: String.t(),
          disconnect: (-> term())
        }

  @doc """
  Adds this session's SSH adapter settings to Termite terminal options.

  The SSH adapter and channel override values supplied in `opts`. Most callers
  should use `Termite.SSH.terminal/1`; this function is useful when additional
  adapter options, such as `:reader_target`, are needed.
  """
  @spec terminal_opts(t(), keyword()) :: keyword()
  def terminal_opts(%__MODULE__{channel_pid: channel_pid}, opts \\ []) do
    opts |> Keyword.put(:adapter, Termite.SSH.Adapter) |> Keyword.put(:channel_pid, channel_pid)
  end

  @doc """
  Invokes the session's disconnect callback.

  Prefer the public `Termite.SSH.disconnect/1` wrapper in application code.
  """
  @spec disconnect(t()) :: term()
  def disconnect(%__MODULE__{disconnect: disconnect}) when is_function(disconnect, 0) do
    disconnect.()
  end
end
