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
end
