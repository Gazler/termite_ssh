defmodule Termite.SSHTest do
  use ExUnit.Case, async: false

  require Logger

  @ssh_timeout 1_000
  @receive_timeout 1_000
  @connect_attempts 10
  @connect_sleep_ms 25

  setup do
    logger_level = Logger.level()
    primary_config = :logger.get_primary_config()
    Logger.configure(level: :error)
    :logger.set_primary_config(:level, :error)

    on_exit(fn ->
      Logger.configure(level: logger_level)
      Enum.each(primary_config, fn {key, value} -> :logger.set_primary_config(key, value) end)
    end)

    :ok
  end

  defmodule SessionServer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      session = Keyword.fetch!(opts, :session)
      terminal = Termite.Terminal.start(Termite.SSH.Session.terminal_opts(session))
      terminal = render(terminal, session.username, 0)

      {:ok,
       %{
         terminal: terminal,
         reader: terminal.reader,
         username: session.username,
         counter: 0,
         parent: Keyword.get(opts, :parent)
       }}
    end

    @impl true
    def handle_info({reader, {:data, "\e[A"}}, %{reader: reader} = state) do
      counter = state.counter + 1
      terminal = render(state.terminal, state.username, counter)
      {:noreply, %{state | terminal: terminal, counter: counter}}
    end

    def handle_info({reader, {:data, "q"}}, %{reader: reader} = state) do
      {:stop, :normal, state}
    end

    def handle_info({reader, {:signal, :hup}}, %{reader: reader, parent: parent} = state) do
      if is_pid(parent), do: send(parent, :hup)
      {:stop, :normal, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(reason, %{parent: parent}) do
      if is_pid(parent), do: send(parent, {:terminated, reason})
      :ok
    end

    defp render(terminal, username, counter) do
      Termite.Terminal.write(terminal, "\e[2J\e[HUser: #{username} Counter: #{counter}\n")
    end
  end

  test "runs a termite session over ssh" do
    port = allocate_port()

    system_dir = test_system_dir()

    {:ok, daemon} =
      Termite.SSH.start_link(
        port: port,
        ip: {127, 0, 0, 1},
        auth: [{"demo", "secret"}],
        system_dir: system_dir,
        entrypoint: {SessionServer, []}
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
    end)

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo",
        password: ~c"secret"
      )

    on_exit(fn -> :ssh.close(conn) end)

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)

    assert :success =
             :ssh_connection.ptty_alloc(conn, channel, term: ~c"xterm", width: 80, height: 24)

    assert :ok = :ssh_connection.shell(conn, channel)

    initial = receive_data(conn, channel)
    assert initial =~ "\e[2J"
    assert initial =~ "User: demo Counter: 0"

    :ok = :ssh_connection.send(conn, channel, "\e[A")
    assert receive_data(conn, channel) =~ "User: demo Counter: 1"

    :ok = :ssh_connection.send(conn, channel, "q")
    assert_receive {:ssh_cm, ^conn, {:closed, ^channel}}, @receive_timeout
  end

  test "accepts no-auth sessions when configured" do
    port = allocate_port()

    system_dir = test_system_dir()

    {:ok, daemon} =
      Termite.SSH.start_link(
        port: port,
        ip: {127, 0, 0, 1},
        auth: :none,
        system_dir: system_dir,
        entrypoint: {SessionServer, []}
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
    end)

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo"
      )

    on_exit(fn -> :ssh.close(conn) end)

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)

    assert :success =
             :ssh_connection.ptty_alloc(conn, channel, term: ~c"xterm", width: 80, height: 24)

    assert :ok = :ssh_connection.shell(conn, channel)

    assert receive_data(conn, channel) =~ "User: demo Counter: 0"
  end

  test "rejects invalid credentials" do
    port = allocate_port()

    system_dir = test_system_dir()

    {:ok, daemon} =
      Termite.SSH.start_link(
        port: port,
        ip: {127, 0, 0, 1},
        auth: [{"demo", "secret"}],
        system_dir: system_dir,
        entrypoint: {SessionServer, []}
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
    end)

    assert {:error, _reason} =
             connect_with_retry(~c"127.0.0.1", port,
               silently_accept_hosts: true,
               user_interaction: false,
               save_accepted_host: false,
               user: ~c"demo",
               password: ~c"wrong"
             )
  end

  test "client disconnect emits hup and stops the session" do
    port = allocate_port()

    system_dir = test_system_dir()
    parent = self()

    {:ok, daemon} =
      Termite.SSH.start_link(
        port: port,
        ip: {127, 0, 0, 1},
        auth: [{"demo", "secret"}],
        system_dir: system_dir,
        entrypoint: {SessionServer, [parent: parent]}
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
    end)

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo",
        password: ~c"secret"
      )

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)

    assert :success =
             :ssh_connection.ptty_alloc(conn, channel, term: ~c"xterm", width: 80, height: 24)

    assert :ok = :ssh_connection.shell(conn, channel)
    _ = receive_data(conn, channel)

    :ok = :ssh.close(conn)
    assert_receive :hup, @receive_timeout
    assert_receive {:terminated, _reason}, @receive_timeout
  end

  defp test_system_dir do
    Path.expand("../../priv/ssh", __DIR__)
  end

  defp allocate_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: 0, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp receive_data(conn, channel, timeout \\ @receive_timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} -> IO.iodata_to_binary(data)
      {:ssh_cm, ^conn, {:eof, ^channel}} -> ""
    after
      timeout -> flunk("timed out waiting for ssh channel data")
    end
  end

  defp connect_with_retry(host, port, opts, attempts \\ @connect_attempts)
  defp connect_with_retry(_host, _port, _opts, 0), do: {:error, :econnrefused}

  defp connect_with_retry(host, port, opts, attempts) do
    case :ssh.connect(host, port, opts) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :econnrefused} ->
        Process.sleep(@connect_sleep_ms)
        connect_with_retry(host, port, opts, attempts - 1)

      other ->
        other
    end
  end
end
