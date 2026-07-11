defmodule Termite.SSH.ChannelTest do
  use ExUnit.Case, async: true

  alias Termite.SSH.Channel

  @receive_timeout 250

  test "window change updates size and emits winch" do
    reader_ref = make_ref()
    state = %Channel{reader_target: self(), reader_ref: reader_ref}

    assert {:ok, %Channel{size: %{width: 120, height: 40}}} =
             Channel.handle_ssh_msg({:ssh_cm, self(), {:window_change, 1, 120, 40, 0, 0}}, state)

    assert_receive {^reader_ref, {:signal, :winch}}, @receive_timeout
  end

  test "input received before terminal attachment is delivered in order" do
    state = %Channel{shell_requested: true}

    assert {:ok, state} =
             Channel.handle_ssh_msg({:ssh_cm, self(), {:data, 1, 0, "first"}}, state)

    assert {:ok, state} =
             Channel.handle_ssh_msg({:ssh_cm, self(), {:data, 1, 0, "second"}}, state)

    reader_ref = make_ref()
    request_ref = make_ref()

    assert {:ok,
            %Channel{
              pending_input: [],
              pending_input_bytes: 0,
              pending_input_chunks: 0
            }} =
             Channel.handle_msg(
               {:terminal_request, self(), request_ref, {:attach_terminal, self(), reader_ref}},
               state
             )

    assert_receive {^reader_ref, {:data, "firstsecond"}}, @receive_timeout
    assert_receive {:terminal_reply, ^request_ref, :ok}, @receive_timeout
  end

  test "empty input does not consume buffer capacity" do
    state = %Channel{shell_requested: true}

    assert {:ok, ^state} =
             Channel.handle_ssh_msg({:ssh_cm, self(), {:data, 1, 0, ""}}, state)
  end

  test "data is rejected before a shell request" do
    conn_ref = stopped_process()
    state = %Channel{}

    assert {:stop, 1, ^state} =
             Channel.handle_ssh_msg({:ssh_cm, conn_ref, {:data, 1, 0, "unexpected"}}, state)
  end

  test "buffer chunk count is bounded independently of byte size" do
    conn_ref = stopped_process()
    state = %Channel{shell_requested: true, pending_input_chunks: 1_024}

    assert {:stop, 1, ^state} =
             Channel.handle_ssh_msg({:ssh_cm, conn_ref, {:data, 1, 0, "x"}}, state)
  end

  test "buffer byte count is bounded" do
    conn_ref = stopped_process()
    state = %Channel{shell_requested: true, pending_input_bytes: 65_536}

    assert {:stop, 1, ^state} =
             Channel.handle_ssh_msg({:ssh_cm, conn_ref, {:data, 1, 0, "x"}}, state)
  end

  test "eof emits hup and shuts down the session process" do
    parent = self()

    session_pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        receive do
          {reader_ref, {:signal, :hup}} ->
            send(parent, {:hup, reader_ref})

            receive do
              {:EXIT, _from, :shutdown} -> send(parent, :session_stopped)
            end
        end
      end)

    reader_ref = make_ref()
    state = %Channel{reader_target: session_pid, reader_ref: reader_ref, session_pid: session_pid}

    assert {:ok, %Channel{} = state} = Channel.handle_ssh_msg({:ssh_cm, self(), {:eof, 1}}, state)
    assert_receive {:hup, ^reader_ref}, @receive_timeout
    assert_receive :shutdown_session, @receive_timeout
    assert {:ok, %Channel{}} = Channel.handle_msg(:shutdown_session, state)
    assert_receive :session_stopped, @receive_timeout
  end

  defp stopped_process do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @receive_timeout
    pid
  end
end
