defmodule Termite.SSH.Session do
  @moduledoc """
  Per-connection session context for SSH-backed terminal applications.
  """

  defstruct [:id, :channel_pid, :username, :disconnect]

  @type t :: %__MODULE__{
          id: reference(),
          channel_pid: pid(),
          username: String.t(),
          disconnect: (-> term())
        }

  @spec terminal_opts(t(), keyword()) :: keyword()
  def terminal_opts(%__MODULE__{channel_pid: channel_pid}, opts \\ []) do
    opts
    |> Keyword.put(:adapter, Termite.SSH.Adapter)
    |> Keyword.put(:channel_pid, channel_pid)
  end

  @spec disconnect(t()) :: term()
  def disconnect(%__MODULE__{disconnect: disconnect}) when is_function(disconnect, 0) do
    disconnect.()
  end
end
