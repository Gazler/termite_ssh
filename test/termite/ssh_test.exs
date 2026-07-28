defmodule Termite.SSHTest do
  use ExUnit.Case, async: false

  @ssh_timeout 1_000
  @receive_timeout 1_000
  @connect_attempts 10
  @connect_sleep_ms 25

  setup_all do
    system_dir = Termite.SSH.TestKeys.create_system_dir()
    user_dir = Termite.SSH.TestKeys.create_user_dir()

    on_exit(fn ->
      File.rm_rf!(system_dir)
      File.rm_rf!(user_dir)
    end)

    {:ok, system_dir: system_dir, user_dir: user_dir}
  end

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
         session: session,
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

    def handle_info({reader, {:data, "q"}}, %{reader: reader, session: session} = state) do
      Termite.SSH.disconnect(session)
      {:stop, :normal, state}
    end

    def handle_info({reader, {:data, "x"}}, %{reader: reader} = state) do
      {:stop, :session_failed, state}
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

  defmodule NeverAttachSession do
    def start_link(_opts) do
      Agent.start_link(fn -> :waiting_for_shutdown end)
    end
  end

  test "runs a termite session over ssh", %{system_dir: system_dir} do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: [{"demo", "secret"}],
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

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
    assert_channel_exit(conn, channel, 0)
  end

  test "reports an abnormal session exit to the SSH client", %{system_dir: system_dir} do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: :none,
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo"
      )

    on_exit(fn -> :ssh.close(conn) end)

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)
    assert :ok = :ssh_connection.shell(conn, channel)
    _ = receive_data(conn, channel)

    :ok = :ssh_connection.send(conn, channel, "x")
    assert_channel_exit(conn, channel, 1)
  end

  test "accepts no-auth sessions when configured", %{system_dir: system_dir} do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: :none,
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

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

  test "rejects invalid credentials", %{system_dir: system_dir} do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: [{"demo", "secret"}],
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    assert {:error, _reason} =
             connect_with_retry(~c"127.0.0.1", port,
               silently_accept_hosts: true,
               user_interaction: false,
               save_accepted_host: false,
               user: ~c"demo",
               password: ~c"wrong"
             )
  end

  test "client disconnect emits hup and stops the session", %{system_dir: system_dir} do
    port = allocate_port()
    parent = self()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: [{"demo", "secret"}],
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, [parent: parent]}
         ]}
      )

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

  test "closes a shell when its terminal does not attach before the deadline", %{
    system_dir: system_dir
  } do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: :none,
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {NeverAttachSession, []},
           terminal_attach_timeout: 25
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo"
      )

    on_exit(fn -> :ssh.close(conn) end)

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)
    assert :ok = :ssh_connection.shell(conn, channel)
    assert_receive {:ssh_cm, ^conn, {:closed, ^channel}}, @receive_timeout
  end

  test "does not expose the default sftp subsystem", %{system_dir: system_dir} do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           ip: {127, 0, 0, 1},
           auth: :none,
           allow_insecure_auth: true,
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        user: ~c"demo"
      )

    on_exit(fn -> :ssh.close(conn) end)

    assert {:error, _reason} = :ssh_sftp.start_channel(conn, timeout: @ssh_timeout)
  end

  test "authenticates with a password verifier", %{system_dir: system_dir} do
    port = allocate_port()
    parent = self()

    verifier = fn username, password, peer, state ->
      send(parent, {:password_attempt, username, password, peer, state})
      {username == "demo" and password == "secret", state}
    end

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           auth: {:password, verifier},
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        auth_methods: ~c"password",
        user: ~c"demo",
        password: ~c"secret"
      )

    on_exit(fn -> :ssh.close(conn) end)

    assert_receive {:password_attempt, "demo", "secret", {{127, 0, 0, 1}, _port}, :undefined},
                   @receive_timeout
  end

  test "decodes Unicode credentials and session usernames as UTF-8", %{
    system_dir: system_dir
  } do
    port = allocate_port()
    parent = self()
    username = "josé🔑"
    password = "sëcret🔒"

    verifier = fn received_username, received_password, _peer, state ->
      send(parent, {:unicode_password_attempt, received_username, received_password})
      {received_username == username and received_password == password, state}
    end

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           auth: {:password, verifier},
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        auth_methods: ~c"password",
        user: to_charlist(username),
        password: to_charlist(password)
      )

    on_exit(fn -> :ssh.close(conn) end)

    assert_receive {:unicode_password_attempt, ^username, ^password}, @receive_timeout

    {:ok, channel} = :ssh_connection.session_channel(conn, @ssh_timeout)
    assert :ok = :ssh_connection.shell(conn, channel)
    assert receive_data(conn, channel) =~ "User: #{username} Counter: 0"

    :ok = :ssh_connection.send(conn, channel, "q")
    assert_channel_exit(conn, channel, 0)
  end

  test "stops the SSH daemon when its owner is killed", %{system_dir: system_dir} do
    port = allocate_port()

    opts = [
      port: port,
      auth: :none,
      allow_insecure_auth: true,
      system_dir: system_dir,
      entrypoint: {SessionServer, []}
    ]

    {:ok, server} = Termite.SSH.start_link(opts)
    Process.unlink(server)

    %{daemon: daemon, daemon_guard: daemon_guard} = :sys.get_state(server)
    server_ref = Process.monitor(server)
    daemon_ref = Process.monitor(daemon)
    daemon_guard_ref = Process.monitor(daemon_guard)

    Process.exit(server, :kill)

    assert_receive {:DOWN, ^server_ref, :process, ^server, :killed}, @receive_timeout
    assert_receive {:DOWN, ^daemon_ref, :process, ^daemon, _reason}, @receive_timeout
    assert_receive {:DOWN, ^daemon_guard_ref, :process, ^daemon_guard, :normal}, @receive_timeout

    {:ok, replacement} = Termite.SSH.start_link(opts)
    Process.unlink(replacement)
    GenServer.stop(replacement)
  end

  test "preserves the daemon exit reason when cleanup sees an exited daemon", %{
    system_dir: system_dir
  } do
    {:ok, server} =
      Termite.SSH.start_link(
        port: allocate_port(),
        auth: :none,
        allow_insecure_auth: true,
        system_dir: system_dir,
        entrypoint: {SessionServer, []}
      )

    Process.unlink(server)
    %{daemon: daemon} = :sys.get_state(server)
    server_ref = Process.monitor(server)

    Process.exit(daemon, :kill)

    assert_receive {:DOWN, ^server_ref, :process, ^server, {:ssh_daemon_exit, :killed}},
                   @receive_timeout
  end

  test "authenticates a username with its authorized public key", %{
    system_dir: system_dir,
    user_dir: user_dir
  } do
    port = allocate_port()

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           auth: {:public_key, [{"demo", user_dir}]},
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    {:ok, conn} =
      connect_with_retry(~c"127.0.0.1", port,
        silently_accept_hosts: true,
        user_interaction: false,
        save_accepted_host: false,
        auth_methods: ~c"publickey",
        user_dir: to_charlist(user_dir),
        user: ~c"demo"
      )

    on_exit(fn -> :ssh.close(conn) end)
  end

  test "public-key verifier reflects runtime authorization changes", %{
    system_dir: system_dir,
    user_dir: user_dir
  } do
    port = allocate_port()
    parent = self()
    {:ok, allowed_keys} = Agent.start_link(fn -> MapSet.new() end)

    verifier = fn username, public_key ->
      send(parent, {:public_key_attempt, username, public_key})
      Agent.get(allowed_keys, &MapSet.member?(&1, {username, public_key}))
    end

    _server =
      start_supervised!(
        {Termite.SSH,
         [
           port: port,
           auth: {:public_key, verifier},
           system_dir: system_dir,
           entrypoint: {SessionServer, []}
         ]}
      )

    connect_opts = [
      silently_accept_hosts: true,
      user_interaction: false,
      save_accepted_host: false,
      auth_methods: ~c"publickey",
      user_dir: to_charlist(user_dir),
      user: ~c"new-user"
    ]

    assert {:error, _reason} = connect_with_retry(~c"127.0.0.1", port, connect_opts)
    assert_receive {:public_key_attempt, "new-user", public_key}, @receive_timeout

    Agent.update(allowed_keys, &MapSet.put(&1, {"new-user", public_key}))

    assert {:ok, conn} = connect_with_retry(~c"127.0.0.1", port, connect_opts)
    on_exit(fn -> :ssh.close(conn) end)
  end

  test "requires acknowledgement for insecure authentication on every interface", %{
    system_dir: system_dir
  } do
    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0}], auth <- [:none, [{"demo", "secret"}]] do
      assert_raise ArgumentError, ~r/requires :allow_insecure_auth to be true/, fn ->
        Termite.SSH.start_link(
          ip: ip,
          auth: auth,
          system_dir: system_dir,
          entrypoint: {SessionServer, []}
        )
      end
    end
  end

  test "allows explicitly acknowledged insecure authentication on every interface", %{
    system_dir: system_dir
  } do
    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0}], auth <- [:none, [{"demo", "secret"}]] do
      assert {:ok, server} =
               Termite.SSH.start_link(
                 ip: ip,
                 port: allocate_port(),
                 auth: auth,
                 allow_insecure_auth: true,
                 system_dir: system_dir,
                 entrypoint: {SessionServer, []}
               )

      GenServer.stop(server)
    end
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

  defp assert_channel_exit(conn, channel, status) do
    assert_receive {:ssh_cm, ^conn, {:exit_status, ^channel, ^status}}, @receive_timeout
    assert_receive {:ssh_cm, ^conn, {:eof, ^channel}}, @receive_timeout
    assert_receive {:ssh_cm, ^conn, {:closed, ^channel}}, @receive_timeout
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
