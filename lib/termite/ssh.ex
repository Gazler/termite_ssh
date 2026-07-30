defmodule Termite.SSH do
  @moduledoc """
  Runs Termite terminal applications over SSH.

  Add `Termite.SSH` to your application's supervision tree. Each accepted SSH
  shell starts one temporary child under an internal `DynamicSupervisor`. The
  configured entrypoint receives the connection's `Termite.SSH.Session` in its
  startup options.

  ## Example

      children = [
        {Termite.SSH,
         name: MyApp.SSH,
         port: 2222,
         auth:
           {:public_key,
            [{System.fetch_env!("SSH_USER"), System.fetch_env!("SSH_AUTHORIZED_KEYS_DIR")}]},
         system_dir: Application.app_dir(:my_app, "priv/ssh"),
         entrypoint: {MyApp.TerminalSession, []}}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The entrypoint must provide `start_link/1` or `child_spec/1`. The session is
  inserted into its keyword options under `:session`, replacing any existing
  value. The authenticated SSH username is available as `session.username`:

      def start_link(opts) do
        session = Keyword.fetch!(opts, :session)

        Task.start_link(fn ->
          terminal = Termite.SSH.terminal(session)
          run_terminal_application(terminal)
          Termite.SSH.disconnect(session)
        end)
      end

  When an attached PTY shell closes or the application shuts down normally, the
  SSH channel makes a best-effort attempt to restore common terminal modes
  before disconnecting. This cannot restore the terminal if the Erlang node or
  network connection has already been lost.

  ## Options

  The following options are required:

    * `:auth` - authentication configuration. Use
      `{:public_key, users_or_verifier}` or `{:password, verifier}` outside
      local development. See "Authentication" below. `:none` and plaintext
      credential lists are intended for local development only and require
      `allow_insecure_auth: true`.
    * `:system_dir` - directory containing at least one `ssh_host_*_key` host
      key. Run `mix termite.ssh.gen_host_key` to create a development key.
    * `:entrypoint` - `{module, keyword_options}` used to start each session.

  Optional settings are:

    * `:port` - listening port. Defaults to `2222`.
    * `:ip` - listening address. Defaults to the loopback address
      `{127, 0, 0, 1}`.
    * `:allow_insecure_auth` - permits `:none` or a plaintext credential list
      when set to `true`. Defaults to `false`. Using it logs a warning.
    * `:name` - name for the SSH server process.
    * `:session_supervisor_name` - explicit name for the internal session
      supervisor. For example, when `:name` is `MyApp.SSH`, this defaults to
      `MyApp.SSH.SessionSupervisor`.
    * `:max_sessions` - maximum simultaneous SSH connections. Defaults to
      `100`.
    * `:max_channels` - maximum active channels per connection. Defaults to
      `1`.
    * `:terminal_attach_timeout` - milliseconds allowed for the entrypoint to
      attach its terminal after the shell request, or `:infinity`. Defaults to
      `5_000`.
    * `:hello_timeout` - milliseconds allowed for the client's first SSH
      message. Defaults to `10_000`.
    * `:negotiation_timeout` - milliseconds allowed for key exchange and
      authentication. Defaults to `30_000`.
    * `:max_initial_idle_time` - milliseconds an authenticated connection may
      wait before opening its first channel. Defaults to `10_000`.
    * `:idle_time` - milliseconds a connection may remain open without any
      channels. Defaults to `60_000`.
    * `:max_reader_queue_length` - maximum number of messages allowed in the
      terminal reader's mailbox before an input-flooding client is
      disconnected. Defaults to `64`.
    * `:max_terminal_width` and `:max_terminal_height` - upper bounds for
      client-supplied terminal dimensions. Defaults to `500` by `200`.

  ## Authentication

  Public-key authentication associates each SSH username with a directory
  containing an OpenSSH-compatible `authorized_keys` or `authorized_keys2`
  file:

      auth: {:public_key, [{"alice", "/srv/my_app/ssh/alice"}]}

  A password verifier is an arity-four function:

      auth:
        {:password,
         fn username, password, peer, state ->
           MyApp.Accounts.verify_ssh_password(username, password, peer, state)
         end}

  The verifier receives binary username and password values, the peer address,
  and per-connection state. It must return the same values accepted by OTP's
  `pwdfun/4`: a boolean, `:disconnect`, or `{boolean, new_state}`. Implement
  password verification in constant time and apply rate limiting across
  connections.

  Public keys can instead be authorized dynamically with an arity-two
  verifier:

      auth:
        {:public_key,
         fn username, public_key ->
           MyApp.Accounts.authorized_ssh_key?(username, public_key)
         end}

  It receives a binary username and OTP's decoded public-key value on every
  authentication check and must return a boolean. Keep the lookup bounded and
  free of side effects because SSH clients may present the same key more than
  once. Exceptions, throws, and exits deny authentication.

  ## Security

  `auth: :none` accepts every client without authentication, while a plaintext
  credential list keeps passwords directly in application configuration.
  Either form requires `allow_insecure_auth: true`. The daemon configures no
  SSH subsystems or TCP forwarding, rejects every command execution request,
  and only exposes the Termite CLI channel.
  """

  use GenServer

  require Logger

  alias Termite.SSH.Channel
  alias Termite.SSH.Session

  @default_max_sessions 100
  @default_max_channels 1
  @default_terminal_attach_timeout 5_000
  @default_hello_timeout 10_000
  @default_negotiation_timeout 30_000
  @default_max_initial_idle_time 10_000
  @default_idle_time 60_000
  @default_max_reader_queue_length 64
  @default_max_terminal_width 500
  @default_max_terminal_height 200
  @session_shutdown_grace_ms 100
  @session_kill_timeout 5_000
  @channel_shutdown_timeout 1_250

  defstruct [
    :daemon,
    :daemon_ref,
    :daemon_guard,
    :daemon_guard_ref,
    :entrypoint,
    :session_supervisor,
    shutdown_prepared?: false,
    sessions: %{}
  ]

  @typedoc "Result returned by a password verifier."
  @type password_auth_result :: boolean() | :disconnect | {boolean(), term()}

  @typedoc "Password verifier called by the SSH authentication layer."
  @type password_auth_fun :: (String.t(),
                              String.t(),
                              {:inet.ip_address(), :inet.port_number()},
                              term() ->
                                password_auth_result())

  @typedoc "Public-key verifier called by the SSH authentication layer."
  @type public_key_auth_fun :: (String.t(), :public_key.public_key() -> boolean())

  @typedoc "SSH authentication configuration."
  @type auth_option ::
          :none
          | [{String.t(), String.t()}]
          | {:password, password_auth_fun()}
          | {:public_key, public_key_auth_fun() | [{String.t(), String.t()}]}

  @typedoc "Option accepted by `start_link/1`."
  @type option ::
          {:port, pos_integer()}
          | {:ip, :inet.ip_address()}
          | {:allow_insecure_auth, boolean()}
          | {:auth, auth_option()}
          | {:system_dir, String.t()}
          | {:entrypoint, {module(), keyword()}}
          | {:name, GenServer.name()}
          | {:session_supervisor_name, GenServer.name()}
          | {:max_sessions, pos_integer()}
          | {:max_channels, pos_integer()}
          | {:terminal_attach_timeout, timeout()}
          | {:hello_timeout, timeout()}
          | {:negotiation_timeout, timeout()}
          | {:max_initial_idle_time, timeout()}
          | {:idle_time, timeout()}
          | {:max_reader_queue_length, pos_integer()}
          | {:max_terminal_width, pos_integer()}
          | {:max_terminal_height, pos_integer()}

  @doc """
  Starts an SSH server linked to the caller.

  This function is normally invoked by a supervisor. See the module
  documentation for required options and defaults.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    validate_auth_binding!(opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Starts and attaches a Termite terminal for `session`.

  Call this from the session entrypoint process. Input, output, resize signals,
  and disconnect signals are routed through the session's SSH channel.
  """
  @spec terminal(Session.t()) :: %Termite.Terminal{}
  def terminal(%Session{} = session) do
    session |> Session.terminal_opts() |> Termite.Terminal.start()
  end

  @doc """
  Requests that the SSH channel for `session` be closed.

  Session entrypoints should call this after their terminal application exits
  normally. Client disconnects are delivered to the terminal reader as
  `{:signal, :hup}`.
  """
  @spec disconnect(Session.t()) :: term()
  def disconnect(%Session{} = session), do: Session.disconnect(session)

  @doc false
  def prepare_shutdown(server, timeout \\ 2_000) when is_pid(server) do
    GenServer.call(server, :prepare_shutdown, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    entrypoint = Keyword.fetch!(opts, :entrypoint)

    with {:ok, session_supervisor} <- DynamicSupervisor.start_link(session_supervisor_opts(opts)),
         {:ok, _apps} <- Application.ensure_all_started(:ssh),
         {:ok, daemon, daemon_guard, daemon_guard_ref} <- start_daemon_ref(opts, self()) do
      Termite.SSH.Application.register_server()

      {:ok,
       %__MODULE__{
         daemon: daemon,
         daemon_ref: Process.monitor(daemon),
         daemon_guard: daemon_guard,
         daemon_guard_ref: daemon_guard_ref,
         entrypoint: entrypoint,
         session_supervisor: session_supervisor
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:prepare_shutdown, _from, %{shutdown_prepared?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:prepare_shutdown, _from, state) do
    stop_listener(state.daemon)
    prepare_channels_for_shutdown(state.sessions)
    {:reply, :ok, %{state | shutdown_prepared?: true}}
  end

  @impl true
  def handle_info({:start_session, pid, %Session{channel_pid: pid} = session}, state)
      when is_pid(pid) do
    channel_ref = Process.monitor(pid)

    if Process.alive?(pid) do
      case start_entrypoint(state, session) do
        {:ok, session_pid} ->
          send(pid, {:session_started, session_pid})

          sessions =
            Map.put(state.sessions, channel_ref, %{channel_pid: pid, session_pid: session_pid})

          {:noreply, %{state | sessions: sessions}}

        {:error, reason} ->
          Process.demonitor(channel_ref, [:flush])
          send(pid, {:session_start_failed, reason})
          {:noreply, state}
      end
    else
      Process.demonitor(channel_ref, [:flush])
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, daemon_ref, :process, daemon, reason},
        %{
          daemon: daemon,
          daemon_ref: daemon_ref,
          shutdown_prepared?: true
        } = state
      )
      when reason in [:normal, :shutdown] do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, daemon_ref, :process, daemon, reason},
        %{daemon: daemon, daemon_ref: daemon_ref} = state
      ) do
    {:stop, {:ssh_daemon_exit, reason}, state}
  end

  def handle_info(
        {:DOWN, daemon_guard_ref, :process, daemon_guard, reason},
        %{daemon_guard: daemon_guard, daemon_guard_ref: daemon_guard_ref} = state
      ) do
    {:stop, {:ssh_daemon_guard_exit, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, channel_pid, _reason}, state) do
    case Map.pop(state.sessions, ref) do
      {nil, _sessions} ->
        {:noreply, state}

      {%{channel_pid: ^channel_pid, session_pid: session_pid}, sessions} ->
        Process.send_after(
          self(),
          {:shutdown_disconnected_session, session_pid},
          @session_shutdown_grace_ms
        )

        {:noreply, %{state | sessions: sessions}}
    end
  end

  def handle_info({:shutdown_disconnected_session, session_pid}, state) do
    if Process.alive?(session_pid) do
      Process.exit(session_pid, :shutdown)

      Process.send_after(self(), {:kill_disconnected_session, session_pid}, @session_kill_timeout)
    end

    {:noreply, state}
  end

  def handle_info({:kill_disconnected_session, session_pid}, state) do
    if Process.alive?(session_pid), do: Process.exit(session_pid, :kill)
    {:noreply, state}
  end

  def handle_info(
        {:EXIT, session_supervisor, reason},
        %{session_supervisor: session_supervisor} = state
      ) do
    {:stop, {:session_supervisor_exit, reason}, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: daemon, shutdown_prepared?: true}) when is_pid(daemon) do
    stop_daemon(daemon)
  end

  def terminate(_reason, %{daemon: daemon} = state) when is_pid(daemon) do
    stop_listener(daemon)
    prepare_channels_for_shutdown(state.sessions)
    stop_daemon(daemon)
  end

  def terminate(_reason, _state), do: :ok

  defp start_daemon_ref(opts, owner) do
    caller = self()
    request_ref = make_ref()

    {guard, guard_ref} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)

        case start_daemon(opts, owner) do
          {:ok, daemon} = result ->
            daemon_ref = Process.monitor(daemon)
            send(caller, {request_ref, self(), result})
            guard_daemon(owner_ref, daemon, daemon_ref)

          error ->
            send(caller, {request_ref, self(), error})
        end
      end)

    receive do
      {^request_ref, ^guard, {:ok, daemon}} ->
        {:ok, daemon, guard, guard_ref}

      {^request_ref, ^guard, {:error, reason}} ->
        Process.demonitor(guard_ref, [:flush])
        {:error, reason}

      {:DOWN, ^guard_ref, :process, ^guard, reason} ->
        {:error, {:ssh_daemon_guard_exit, reason}}
    end
  end

  defp start_daemon(opts, owner) do
    port = Keyword.get(opts, :port, 2222)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    system_dir = opts |> Keyword.fetch!(:system_dir) |> resolve_system_dir!()

    daemon_opts =
      [
        ifaddr: ip,
        system_dir: to_charlist(system_dir),
        max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
        max_channels: Keyword.get(opts, :max_channels, @default_max_channels),
        hello_timeout: Keyword.get(opts, :hello_timeout, @default_hello_timeout),
        negotiation_timeout:
          Keyword.get(opts, :negotiation_timeout, @default_negotiation_timeout),
        max_initial_idle_time:
          Keyword.get(opts, :max_initial_idle_time, @default_max_initial_idle_time),
        idle_time: Keyword.get(opts, :idle_time, @default_idle_time),
        parallel_login: false,
        tcpip_tunnel_in: false,
        tcpip_tunnel_out: false,
        id_string: :random,
        subsystems: [],
        ssh_cli: {Channel, channel_opts(opts, owner)}
      ] ++ auth_opts(Keyword.fetch!(opts, :auth))

    :ssh.daemon(port, daemon_opts)
  end

  defp guard_daemon(owner_ref, daemon, daemon_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        stop_daemon(daemon)

      {:DOWN, ^daemon_ref, :process, ^daemon, _reason} ->
        guard_owner(owner_ref)
    end
  end

  defp guard_owner(owner_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, _owner, _reason} -> :ok
    end
  end

  defp stop_daemon(daemon) do
    :ssh.stop_daemon(daemon)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp stop_listener(daemon) do
    :ssh.stop_listener(daemon)
  rescue
    MatchError -> :ok
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp prepare_channels_for_shutdown(sessions) do
    pending =
      Enum.reduce(sessions, %{}, fn {_monitor_ref, %{channel_pid: channel_pid}}, pending ->
        if Process.alive?(channel_pid) do
          request_ref = make_ref()
          send(channel_pid, {:prepare_shutdown, self(), request_ref})
          Map.put(pending, request_ref, channel_pid)
        else
          pending
        end
      end)

    await_prepared_channels(
      pending,
      System.monotonic_time(:millisecond) + @channel_shutdown_timeout
    )
  end

  defp await_prepared_channels(pending, _deadline) when map_size(pending) == 0, do: :ok

  defp await_prepared_channels(pending, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:channel_shutdown_prepared, ref, channel_pid} ->
        case Map.pop(pending, ref) do
          {^channel_pid, pending} -> await_prepared_channels(pending, deadline)
          _unknown -> await_prepared_channels(pending, deadline)
        end
    after
      timeout -> :ok
    end
  end

  defp channel_opts(opts, owner) do
    [
      owner: owner,
      terminal_attach_timeout:
        Keyword.get(opts, :terminal_attach_timeout, @default_terminal_attach_timeout),
      max_reader_queue_length:
        Keyword.get(opts, :max_reader_queue_length, @default_max_reader_queue_length),
      max_terminal_width: Keyword.get(opts, :max_terminal_width, @default_max_terminal_width),
      max_terminal_height: Keyword.get(opts, :max_terminal_height, @default_max_terminal_height)
    ]
  end

  @doc false
  def session_supervisor_opts(opts) do
    case session_supervisor_name(opts) do
      nil -> [strategy: :one_for_one]
      name -> [strategy: :one_for_one, name: name]
    end
  end

  @doc false
  def session_supervisor_name(opts) do
    Keyword.get(opts, :session_supervisor_name) ||
      derive_session_supervisor_name(Keyword.get(opts, :name))
  end

  defp derive_session_supervisor_name(name) when is_atom(name) and not is_nil(name) do
    Module.concat(name, SessionSupervisor)
  end

  defp derive_session_supervisor_name(_name), do: nil

  defp auth_opts(:none), do: [no_auth_needed: true]

  defp auth_opts({:password, verifier}) do
    password_verifier = fn username, password, peer, state ->
      verifier.(to_binary(username), to_binary(password), peer, state)
    end

    [auth_methods: ~c"password", pwdfun: password_verifier]
  end

  defp auth_opts({:public_key, verifier}) when is_function(verifier, 2) do
    [auth_methods: ~c"publickey", key_cb: {Termite.SSH.KeyCallback, [verifier: verifier]}]
  end

  defp auth_opts({:public_key, users}) do
    user_dirs =
      Map.new(users, fn {username, directory} ->
        {to_charlist(username), to_charlist(directory)}
      end)

    [auth_methods: ~c"publickey", key_cb: {Termite.SSH.KeyCallback, [user_dirs: user_dirs]}]
  end

  defp auth_opts(user_passwords) when is_list(user_passwords) do
    [
      auth_methods: ~c"password",
      user_passwords:
        Enum.map(user_passwords, fn {username, password} ->
          {to_charlist(username), to_charlist(password)}
        end)
    ]
  end

  defp validate_auth_binding!(opts) do
    auth = Keyword.fetch!(opts, :auth)

    if insecure_auth?(auth) do
      if Keyword.get(opts, :allow_insecure_auth, false) do
        Logger.warning(
          "Termite.SSH is starting with #{insecure_auth_description(auth)} because " <>
            ":allow_insecure_auth is true"
        )
      else
        raise ArgumentError, "insecure authentication requires :allow_insecure_auth to be true"
      end
    end
  end

  defp insecure_auth?(:none), do: true
  defp insecure_auth?(auth), do: is_list(auth)

  defp insecure_auth_description(:none), do: "authentication disabled"
  defp insecure_auth_description(_auth), do: "a plaintext credential list"

  defp resolve_system_dir!(dir) do
    case Path.wildcard(Path.join(dir, "ssh_host_*_key")) do
      [] ->
        raise ArgumentError,
              "Termite.SSH requires a system_dir containing ssh_host_*_key files: #{dir}"

      _keys ->
        dir
    end
  end

  defp start_entrypoint(state, session) do
    {mod, args} = state.entrypoint
    args = Keyword.put(args, :session, session)

    try do
      child_spec = entrypoint_child_spec(mod, args, session)

      case DynamicSupervisor.start_child(state.session_supervisor, child_spec) do
        {:ok, pid} -> {:ok, pid}
        {:ok, pid, _info} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
        :ignore -> {:error, :ignore}
      end
    rescue
      exception ->
        Logger.error(Exception.format(:error, exception, __STACKTRACE__))
        {:error, {:entrypoint_exception, exception}}
    catch
      kind, reason ->
        Logger.error(Exception.format(kind, reason, __STACKTRACE__))
        {:error, {:entrypoint_exception, {kind, reason}}}
    end
  end

  defp entrypoint_child_spec(mod, args, session) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :child_spec, 1) do
      mod
      |> apply(:child_spec, [args])
      |> Supervisor.child_spec(id: {mod, session.id}, restart: :temporary)
    else
      %{
        id: {mod, session.id},
        start: {mod, :start_link, [args]},
        type: :worker,
        restart: :temporary
      }
    end
  end

  defp to_binary(value), do: IO.chardata_to_string(value)
end
