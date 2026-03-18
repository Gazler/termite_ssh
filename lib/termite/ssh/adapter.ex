defmodule Termite.SSH.Adapter do
  @moduledoc false

  @behaviour Termite.Terminal.Adapter

  alias Termite.Terminal.Adapter

  defstruct [:channel_pid, :reader_ref]

  @impl Adapter
  def start(opts) do
    channel_pid = Keyword.fetch!(opts, :channel_pid)
    reader_ref = make_ref()
    reader_target = Keyword.get(opts, :reader_target, self())

    case request(channel_pid, {:attach_terminal, reader_target, reader_ref}) do
      :ok ->
        {:ok, %__MODULE__{channel_pid: channel_pid, reader_ref: reader_ref}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Adapter
  def reader(%__MODULE__{reader_ref: reader_ref}) do
    {:ok, reader_ref}
  end

  @impl Adapter
  def write(%__MODULE__{channel_pid: channel_pid} = terminal, string) do
    string =
      string
      |> String.replace("\r\n", "\n")
      |> String.replace("\n", "\r\n")

    case request(channel_pid, {:write, string}) do
      :ok -> {:ok, terminal}
      {:error, :closed} -> {:ok, terminal}
      {:error, :timeout} -> {:ok, terminal}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Adapter
  def resize(%__MODULE__{channel_pid: channel_pid}) do
    case request(channel_pid, :size) do
      %{width: width, height: height} = size when is_integer(width) and is_integer(height) ->
        size

      _ ->
        %{width: 80, height: 24}
    end
  end

  defp request(channel_pid, payload, timeout \\ 5_000) do
    ref = make_ref()
    monitor_ref = Process.monitor(channel_pid)
    send(channel_pid, {:terminal_request, self(), ref, payload})

    receive do
      {:terminal_reply, ^ref, reply} ->
        Process.demonitor(monitor_ref, [:flush])
        reply

      {:DOWN, ^monitor_ref, :process, ^channel_pid, _reason} ->
        {:error, :closed}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end
end
