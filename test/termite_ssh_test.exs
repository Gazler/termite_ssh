defmodule TermiteSshTest do
  use ExUnit.Case, async: true

  defmodule PlainEntrypoint do
    def start_link(opts) do
      session = Keyword.fetch!(opts, :session)
      Agent.start_link(fn -> session.username end)
    end
  end

  defmodule ChildSpecEntrypoint do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> Keyword.fetch!(opts, :session).username end]},
        restart: :temporary
      }
    end
  end

  defmodule FailingEntrypoint do
    def start_link(_opts), do: {:error, :boom}
  end

  test "terminal_opts configures the ssh adapter" do
    session = %Termite.SSH.Session{
      id: make_ref(),
      channel_pid: self(),
      username: "demo",
      disconnect: fn -> :ok end
    }

    opts = Termite.SSH.Session.terminal_opts(session)

    assert Keyword.get(opts, :adapter) == Termite.SSH.Adapter
    assert Keyword.get(opts, :channel_pid) == self()
  end

  test "public-key authentication fails closed for unknown usernames" do
    options = [key_cb_private: [user_dirs: %{}]]
    refute Termite.SSH.KeyCallback.is_auth_key(:unknown_key, ~c"unknown", options)

    raising = [key_cb_private: [verifier: fn _username, _key -> raise "unavailable" end]]
    refute Termite.SSH.KeyCallback.is_auth_key(:unknown_key, ~c"unknown", raising)
  end

  test "public-key verifiers receive Unicode usernames as UTF-8 strings" do
    parent = self()
    username = "josé🔑"

    options = [
      key_cb_private: [
        verifier: fn received_username, key ->
          send(parent, {:public_key_attempt, received_username, key})
          true
        end
      ]
    ]

    assert Termite.SSH.KeyCallback.is_auth_key(:public_key, to_charlist(username), options)
    assert_receive {:public_key_attempt, ^username, :public_key}
  end

  test "session supervisor is named from an atom ssh process name" do
    opts = Termite.SSH.session_supervisor_opts(name: TermiteSshTest.SSH)

    assert opts[:strategy] == :one_for_one
    assert opts[:name] == TermiteSshTest.SSH.SessionSupervisor
  end

  test "session supervisor stays unnamed when the ssh process is unnamed" do
    assert Termite.SSH.session_supervisor_opts([]) == [strategy: :one_for_one]
  end

  test "session supervisor name can be configured explicitly" do
    opts =
      Termite.SSH.session_supervisor_opts(
        name: TermiteSshTest.SSH,
        session_supervisor_name: TermiteSshTest.CustomSessionSupervisor
      )

    assert opts[:strategy] == :one_for_one
    assert opts[:name] == TermiteSshTest.CustomSessionSupervisor
  end

  test "session supervisor stays unnamed when ssh process name cannot derive a module" do
    opts = Termite.SSH.session_supervisor_opts(name: {:global, :termite_ssh})

    assert opts == [strategy: :one_for_one]
  end

  test "start_session supports plain start_link entrypoints" do
    {:ok, session_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %Termite.SSH{
      daemon: self(),
      entrypoint: {PlainEntrypoint, []},
      session_supervisor: session_supervisor
    }

    session = %Termite.SSH.Session{
      id: make_ref(),
      channel_pid: self(),
      username: "demo",
      disconnect: fn -> :ok end
    }

    assert {:noreply, %Termite.SSH{}} =
             Termite.SSH.handle_info({:start_session, self(), session}, state)

    assert_receive {:session_started, pid}
    assert Agent.get(pid, & &1) == "demo"
  end

  test "start_session supports child_spec entrypoints" do
    {:ok, session_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %Termite.SSH{
      daemon: self(),
      entrypoint: {ChildSpecEntrypoint, []},
      session_supervisor: session_supervisor
    }

    session = %Termite.SSH.Session{
      id: make_ref(),
      channel_pid: self(),
      username: "demo",
      disconnect: fn -> :ok end
    }

    assert {:noreply, %Termite.SSH{}} =
             Termite.SSH.handle_info({:start_session, self(), session}, state)

    assert_receive {:session_started, pid}
    assert Agent.get(pid, & &1) == "demo"
  end

  test "start_session reports startup errors" do
    {:ok, session_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %Termite.SSH{
      daemon: self(),
      entrypoint: {FailingEntrypoint, []},
      session_supervisor: session_supervisor
    }

    session = %Termite.SSH.Session{
      id: make_ref(),
      channel_pid: self(),
      username: "demo",
      disconnect: fn -> :ok end
    }

    assert {:noreply, ^state} = Termite.SSH.handle_info({:start_session, self(), session}, state)
    assert_receive {:session_start_failed, :boom}
  end

  test "a disconnected channel cannot leave an orphaned session" do
    {:ok, session_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    parent = self()

    channel_pid =
      spawn(fn ->
        receive do
          {:session_started, session_pid} ->
            send(parent, {:forwarded_session_started, session_pid})
            Process.sleep(:infinity)
        end
      end)

    state = %Termite.SSH{
      daemon: self(),
      entrypoint: {PlainEntrypoint, []},
      session_supervisor: session_supervisor
    }

    session = %Termite.SSH.Session{
      id: make_ref(),
      channel_pid: channel_pid,
      username: "demo",
      disconnect: fn -> :ok end
    }

    assert {:noreply, %Termite.SSH{} = state} =
             Termite.SSH.handle_info({:start_session, channel_pid, session}, state)

    assert_receive {:forwarded_session_started, session_pid}
    session_ref = Process.monitor(session_pid)
    Process.exit(channel_pid, :kill)

    assert_receive {:DOWN, channel_ref, :process, ^channel_pid, :killed}

    assert {:noreply, %Termite.SSH{sessions: sessions} = state} =
             Termite.SSH.handle_info({:DOWN, channel_ref, :process, channel_pid, :killed}, state)

    assert sessions == %{}
    assert_receive {:shutdown_disconnected_session, ^session_pid}, 250

    assert {:noreply, ^state} =
             Termite.SSH.handle_info({:shutdown_disconnected_session, session_pid}, state)

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :shutdown}
  end
end
