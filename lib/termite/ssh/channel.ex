defmodule Termite.SSH.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  alias Termite.SSH.Session

  defstruct [
    :conn_ref,
    :channel_id,
    :owner,
    :session_pid,
    :session_ref,
    :exec_mode,
    :reader_ref,
    :reader_target,
    size: %{width: 80, height: 24}
  ]

  @disconnect_grace_ms 100

  @impl :ssh_server_channel
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{owner: Keyword.fetch!(opts, :owner)}}
  end

  @impl :ssh_server_channel
  def handle_msg({:ssh_channel_up, channel_id, conn_ref}, state) do
    {:ok, %{state | channel_id: channel_id, conn_ref: conn_ref}}
  end

  def handle_msg({:terminal_request, from, ref, {:attach_terminal, target, reader_ref}}, state) do
    send(from, {:terminal_reply, ref, :ok})
    {:ok, %{state | reader_target: target, reader_ref: reader_ref}}
  end

  def handle_msg({:terminal_request, from, ref, {:write, data}}, state) do
    reply =
      if state.conn_ref && state.channel_id do
        :ssh_connection.send(state.conn_ref, state.channel_id, IO.iodata_to_binary(data))
        :ok
      else
        {:error, :channel_not_ready}
      end

    send(from, {:terminal_reply, ref, reply})
    {:ok, state}
  end

  def handle_msg({:terminal_request, from, ref, :size}, state) do
    send(from, {:terminal_reply, ref, state.size})
    {:ok, state}
  end

  def handle_msg({:session_started, pid}, state) do
    {:ok, %{state | session_pid: pid, session_ref: Process.monitor(pid)}}
  end

  def handle_msg(
        {:session_start_failed, _reason},
        %{conn_ref: conn_ref, channel_id: channel_id} = state
      ) do
    :ssh_connection.exit_status(conn_ref, channel_id, 1)
    :ssh_connection.send_eof(conn_ref, channel_id)
    {:stop, channel_id, state}
  end

  def handle_msg(
        {:DOWN, ref, :process, pid, _reason},
        %{session_pid: pid, session_ref: ref, channel_id: channel_id} = state
      ) do
    {:stop, channel_id, state}
  end

  def handle_msg(:session_shutdown, %{channel_id: channel_id} = state) do
    {:stop, channel_id, state}
  end

  def handle_msg({:session_shutdown, _reason}, %{channel_id: channel_id} = state) do
    {:stop, channel_id, state}
  end

  def handle_msg(:shutdown_session, state) do
    shutdown_session(state)
    {:ok, state}
  end

  def handle_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:pty, channel_id, want_reply, {_term, width, height, _, _, _}}},
        state
      ) do
    :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)

    {:ok,
     %{state | conn_ref: conn_ref, channel_id: channel_id, size: normalize_size(width, height)}}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:shell, channel_id, want_reply}}, state) do
    :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)
    start_session(%{state | conn_ref: conn_ref, channel_id: channel_id})
    {:ok, %{state | conn_ref: conn_ref, channel_id: channel_id}}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:exec, channel_id, want_reply, command}}, state) do
    state = %{state | conn_ref: conn_ref, channel_id: channel_id}

    if ghostty_terminfo_command?(command) do
      :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)
      {:ok, %{state | exec_mode: :ghostty_terminfo}}
    else
      :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
      :ssh_connection.exit_status(conn_ref, channel_id, 126)
      :ssh_connection.send_eof(conn_ref, channel_id)
      {:stop, channel_id, state}
    end
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:data, _channel_id, _type, data}}, state) do
    case state.exec_mode do
      :ghostty_terminfo ->
        :ok

      _ ->
        if state.reader_target && state.reader_ref do
          send(state.reader_target, {state.reader_ref, {:data, data}})
        end
    end

    {:ok, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, _conn_ref, {:window_change, _channel_id, width, height, _, _}},
        state
      ) do
    size = normalize_size(width, height)

    if state.reader_target && state.reader_ref do
      send(state.reader_target, {state.reader_ref, {:signal, :winch}})
    end

    {:ok, %{state | size: size}}
  end

  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:eof, channel_id}},
        %{exec_mode: :ghostty_terminfo} = state
      ) do
    :ssh_connection.exit_status(conn_ref, channel_id, 0)
    :ssh_connection.send_eof(conn_ref, channel_id)
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:eof, _channel_id}}, state) do
    state = notify_disconnect(state)
    schedule_shutdown(state)
    {:ok, state}
  end

  def handle_ssh_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def terminate(_reason, state) do
    state = notify_disconnect(state)
    shutdown_session_with_grace(state)
    :ok
  end

  defp start_session(state) do
    channel_pid = self()

    session = %Session{
      id: make_ref(),
      channel_pid: channel_pid,
      username: username(state.conn_ref),
      disconnect: fn -> send(channel_pid, :session_shutdown) end
    }

    send(state.owner, {:start_session, channel_pid, session})
    :ok
  end

  defp normalize_size(width, height) when width > 0 and height > 0 do
    %{width: width, height: height}
  end

  defp normalize_size(_, _), do: %{width: 80, height: 24}

  defp notify_disconnect(state) do
    if state.reader_target && state.reader_ref do
      send(state.reader_target, {state.reader_ref, {:signal, :hup}})
    end

    state
  end

  defp schedule_shutdown(%{session_pid: session_pid}) when is_pid(session_pid) do
    if Process.alive?(session_pid),
      do: Process.send_after(self(), :shutdown_session, @disconnect_grace_ms)

    :ok
  end

  defp schedule_shutdown(_state), do: :ok

  defp shutdown_session_with_grace(%{session_pid: session_pid}) when is_pid(session_pid) do
    if Process.alive?(session_pid) do
      spawn(fn ->
        Process.sleep(@disconnect_grace_ms)

        if Process.alive?(session_pid) do
          Process.exit(session_pid, :shutdown)
        end
      end)
    end

    :ok
  end

  defp shutdown_session_with_grace(_state), do: :ok

  defp shutdown_session(%{session_pid: session_pid}) when is_pid(session_pid) do
    if Process.alive?(session_pid), do: Process.exit(session_pid, :shutdown)
    :ok
  end

  defp shutdown_session(_state), do: :ok

  defp username(conn_ref) do
    case :ssh.connection_info(conn_ref, [:user]) do
      [{:user, username}] -> to_string(username)
      _ -> "guest"
    end
  end

  defp ghostty_terminfo_command?(command) do
    command = IO.iodata_to_binary(command)

    String.contains?(command, "tic") and
      (String.contains?(command, "ghostty") or String.contains?(command, "-x -"))
  end
end
