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
    :reader_ref,
    :reader_target,
    :reader_monitor,
    :attach_timer,
    attach_timeout: 5_000,
    mode: :idle,
    pty_requested: false,
    eof_received: false,
    disconnect_notified: false,
    shutdown_scheduled: false,
    max_reader_queue_length: 64,
    max_terminal_width: 500,
    max_terminal_height: 200,
    pending_input: [],
    pending_input_bytes: 0,
    pending_input_chunks: 0,
    size: %{width: 80, height: 24}
  ]

  @disconnect_grace_ms 100
  @session_kill_timeout 5_000
  @max_pending_input_bytes 65_536
  @max_pending_input_chunks 1_024

  @impl :ssh_server_channel
  def init(opts) do
    max_terminal_width = Keyword.get(opts, :max_terminal_width, 500)
    max_terminal_height = Keyword.get(opts, :max_terminal_height, 200)

    {:ok,
     %__MODULE__{
       owner: Keyword.fetch!(opts, :owner),
       attach_timeout: Keyword.get(opts, :terminal_attach_timeout, 5_000),
       max_reader_queue_length: Keyword.get(opts, :max_reader_queue_length, 64),
       max_terminal_width: max_terminal_width,
       max_terminal_height: max_terminal_height,
       size: default_size(max_terminal_width, max_terminal_height)
     }}
  end

  @impl :ssh_server_channel
  def handle_msg({:ssh_channel_up, channel_id, conn_ref}, state) do
    {:ok, %{state | channel_id: channel_id, conn_ref: conn_ref}}
  end

  def handle_msg(
        {:terminal_request, from, ref, {:attach_terminal, target, reader_ref}},
        %{mode: :shell, reader_target: nil, eof_received: false} = state
      )
      when is_pid(target) do
    if Process.alive?(target) do
      cancel_attach_timer(state.attach_timer)
      reader_monitor = Process.monitor(target)

      if state.pending_input_bytes > 0 do
        data = state.pending_input |> Enum.reverse() |> IO.iodata_to_binary()
        send(target, {reader_ref, {:data, data}})
      end

      send(from, {:terminal_reply, ref, :ok})

      {:ok,
       %{
         state
         | reader_target: target,
           reader_ref: reader_ref,
           reader_monitor: reader_monitor,
           attach_timer: nil,
           pending_input: [],
           pending_input_bytes: 0,
           pending_input_chunks: 0
       }}
    else
      send(from, {:terminal_reply, ref, {:error, :reader_closed}})
      {:ok, state}
    end
  end

  def handle_msg({:terminal_request, from, ref, {:attach_terminal, target, _reader_ref}}, state) do
    reason =
      cond do
        state.eof_received -> :closed
        state.reader_target != nil -> :already_attached
        state.mode != :shell -> :shell_not_started
        not is_pid(target) -> :invalid_reader
        true -> :reader_closed
      end

    send(from, {:terminal_reply, ref, {:error, reason}})
    {:ok, state}
  end

  def handle_msg({:terminal_request, from, ref, {:write, data}}, state) do
    reply =
      if state.conn_ref && state.channel_id do
        with {:ok, data} <- iodata_to_binary(data) do
          ssh_send(state.conn_ref, state.channel_id, data)
        end
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

  def handle_msg({:session_started, pid}, %{session_pid: nil} = state) when is_pid(pid) do
    state = %{state | session_pid: pid, session_ref: Process.monitor(pid)}
    state = if state.eof_received, do: schedule_shutdown(state), else: state
    {:ok, state}
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
        {:DOWN, ref, :process, pid, reason},
        %{reader_target: pid, reader_monitor: ref, channel_id: channel_id} = state
      ) do
    status = if state.session_pid == pid, do: session_exit_status(reason), else: 1
    close_channel(channel_id, status, state)
  end

  def handle_msg(
        {:DOWN, ref, :process, pid, reason},
        %{session_pid: pid, session_ref: ref, channel_id: channel_id} = state
      ) do
    close_channel(channel_id, session_exit_status(reason), state)
  end

  def handle_msg(:session_shutdown, %{channel_id: channel_id} = state) do
    close_channel(channel_id, 0, state)
  end

  def handle_msg({:session_shutdown, reason}, %{channel_id: channel_id} = state) do
    close_channel(channel_id, session_exit_status(reason), state)
  end

  def handle_msg(:shutdown_session, state) do
    shutdown_session(state)
    {:ok, state}
  end

  def handle_msg({:kill_session, session_pid}, %{session_pid: session_pid} = state) do
    if Process.alive?(session_pid), do: Process.exit(session_pid, :kill)
    {:ok, state}
  end

  def handle_msg(
        {:terminal_attach_timeout, token},
        %{attach_timer: {_timer_ref, token}, conn_ref: conn_ref, channel_id: channel_id} = state
      ) do
    fail_channel(conn_ref, channel_id, %{state | attach_timer: nil})
  end

  def handle_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:pty, channel_id, want_reply, {_term, width, height, _, _, _}}},
        %{mode: :idle, pty_requested: false} = state
      ) do
    :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)

    {:ok,
     %{
       state
       | conn_ref: conn_ref,
         channel_id: channel_id,
         pty_requested: true,
         size: normalize_size(width, height, state)
     }}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:pty, channel_id, want_reply, _pty}}, state) do
    :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:shell, channel_id, want_reply}}, %{mode: mode} = state) do
    if mode == :idle do
      :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)

      state = %{
        state
        | conn_ref: conn_ref,
          channel_id: channel_id,
          mode: :shell,
          attach_timer: schedule_attach_timeout(state.attach_timeout)
      }

      start_session(state)
      {:ok, state}
    else
      :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
      {:ok, state}
    end
  end

  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:exec, channel_id, want_reply, _command}},
        %{mode: :idle} = state
      ) do
    state = %{state | conn_ref: conn_ref, channel_id: channel_id}
    :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
    :ssh_connection.exit_status(conn_ref, channel_id, 126)
    :ssh_connection.send_eof(conn_ref, channel_id)
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:exec, channel_id, want_reply, _command}}, state) do
    :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:data, channel_id, 0, data}}, state) do
    cond do
      state.mode != :shell ->
        fail_channel(conn_ref, channel_id, state)

      data == "" ->
        {:ok, state}

      state.reader_target && state.reader_ref ->
        case deliver_reader_message(state, {:data, data}) do
          :ok -> {:ok, state}
          {:error, _reason} -> fail_channel(conn_ref, channel_id, state)
        end

      true ->
        buffer_input(conn_ref, channel_id, data, state)
    end
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:data, channel_id, _type, _data}}, state) do
    fail_channel(conn_ref, channel_id, state)
  end

  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:window_change, channel_id, width, height, _, _}},
        state
      ) do
    state = %{state | size: normalize_size(width, height, state)}

    case deliver_reader_message(state, {:signal, :winch}) do
      :ok -> {:ok, state}
      {:error, :not_attached} -> {:ok, state}
      {:error, _reason} -> fail_channel(conn_ref, channel_id, state)
    end
  end

  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:env, channel_id, want_reply, _variable, _value}},
        state
      ) do
    :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:eof, _channel_id}}, %{mode: :shell} = state) do
    state = %{state | eof_received: true}
    state = state |> notify_disconnect() |> schedule_shutdown()
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:eof, channel_id}}, state) do
    fail_channel(conn_ref, channel_id, state)
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:signal, _channel_id, _signal}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, _conn_ref, {:exit_signal, channel_id, _signal, _error, _language}},
        state
      ) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def terminate(_reason, state) do
    cancel_attach_timer(state.attach_timer)
    _state = notify_disconnect(state)
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

  defp normalize_size(width, height, state) when width > 0 and height > 0 do
    %{width: min(width, state.max_terminal_width), height: min(height, state.max_terminal_height)}
  end

  defp normalize_size(_, _, state) do
    default_size(state.max_terminal_width, state.max_terminal_height)
  end

  defp default_size(max_width, max_height) do
    %{width: min(80, max_width), height: min(24, max_height)}
  end

  defp buffer_input(conn_ref, channel_id, data, state) do
    pending_input_bytes = state.pending_input_bytes + byte_size(data)
    pending_input_chunks = state.pending_input_chunks + 1

    if pending_input_bytes <= @max_pending_input_bytes and
         pending_input_chunks <= @max_pending_input_chunks do
      {:ok,
       %{
         state
         | pending_input: [data | state.pending_input],
           pending_input_bytes: pending_input_bytes,
           pending_input_chunks: pending_input_chunks
       }}
    else
      fail_channel(conn_ref, channel_id, state)
    end
  end

  defp schedule_attach_timeout(:infinity), do: nil

  defp schedule_attach_timeout(timeout) when is_integer(timeout) and timeout >= 0 do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:terminal_attach_timeout, token}, timeout)
    {timer_ref, token}
  end

  defp cancel_attach_timer(nil), do: :ok

  defp cancel_attach_timer({timer_ref, _token}) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp fail_channel(conn_ref, channel_id, state) do
    :ssh_connection.exit_status(conn_ref, channel_id, 1)
    :ssh_connection.send_eof(conn_ref, channel_id)
    {:stop, channel_id, state}
  end

  defp close_channel(channel_id, status, %{conn_ref: conn_ref} = state) do
    :ssh_connection.exit_status(conn_ref, channel_id, status)
    :ssh_connection.send_eof(conn_ref, channel_id)
    {:stop, channel_id, state}
  end

  defp session_exit_status(:normal), do: 0
  defp session_exit_status(:shutdown), do: 0
  defp session_exit_status({:shutdown, _reason}), do: 0
  defp session_exit_status(_reason), do: 1

  defp notify_disconnect(%{disconnect_notified: false} = state) do
    if state.reader_target && state.reader_ref && Process.alive?(state.reader_target) do
      send(state.reader_target, {state.reader_ref, {:signal, :hup}})
    end

    %{state | disconnect_notified: true}
  end

  defp notify_disconnect(state), do: state

  defp deliver_reader_message(%{reader_target: nil}, _message), do: {:error, :not_attached}

  defp deliver_reader_message(state, message) do
    case Process.info(state.reader_target, :message_queue_len) do
      {:message_queue_len, length} when length < state.max_reader_queue_length ->
        send(state.reader_target, {state.reader_ref, message})
        :ok

      {:message_queue_len, _length} ->
        {:error, :reader_overloaded}

      nil ->
        {:error, :reader_closed}
    end
  end

  defp schedule_shutdown(%{shutdown_scheduled: true} = state), do: state

  defp schedule_shutdown(%{session_pid: session_pid} = state) when is_pid(session_pid) do
    if Process.alive?(session_pid) do
      Process.send_after(self(), :shutdown_session, @disconnect_grace_ms)
      %{state | shutdown_scheduled: true}
    else
      state
    end
  end

  defp schedule_shutdown(state), do: state

  defp shutdown_session(%{session_pid: session_pid}) when is_pid(session_pid) do
    if Process.alive?(session_pid) do
      Process.exit(session_pid, :shutdown)
      Process.send_after(self(), {:kill_session, session_pid}, @session_kill_timeout)
    end

    :ok
  end

  defp shutdown_session(_state), do: :ok

  defp ssh_send(conn_ref, channel_id, data) do
    case :ssh_connection.send(conn_ref, channel_id, data, 5_000) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp iodata_to_binary(data) do
    {:ok, IO.iodata_to_binary(data)}
  rescue
    ArgumentError -> {:error, :invalid_data}
  end

  defp username(conn_ref) do
    case :ssh.connection_info(conn_ref, [:user]) do
      [{:user, username}] -> IO.chardata_to_string(username)
      _ -> "guest"
    end
  rescue
    _exception -> "guest"
  end
end
