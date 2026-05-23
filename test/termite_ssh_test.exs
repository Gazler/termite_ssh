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

  test "session supervisor is named from an atom ssh process name" do
    opts = Termite.SSH.session_supervisor_opts(name: TermiteSshTest.SSH)

    assert opts[:strategy] == :one_for_one
    assert opts[:name] == TermiteSshTest.SSH.SessionSupervisor
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

    assert {:noreply, ^state} = Termite.SSH.handle_info({:start_session, self(), session}, state)
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

    assert {:noreply, ^state} = Termite.SSH.handle_info({:start_session, self(), session}, state)
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
end
