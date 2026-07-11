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
         auth: [{System.fetch_env!("SSH_USER"), System.fetch_env!("SSH_PASSWORD")}],
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

  ## Options

  The following options are required:

    * `:auth` - either `:none` or a list of `{username, password}` pairs.
    * `:system_dir` - directory containing at least one `ssh_host_*_key` host
      key. Run `mix termite.ssh.gen_host_key` to create a development key.
    * `:entrypoint` - `{module, keyword_options}` used to start each session.

  Optional settings are:

    * `:port` - listening port. Defaults to `2222`.
    * `:ip` - listening address. Defaults to the loopback address
      `{127, 0, 0, 1}`.
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

  ## Security

  `auth: :none` accepts every client without authentication. Use it only on a
  trusted network, normally with the default loopback binding. SFTP and other
  SSH subsystems are disabled; the daemon only exposes the Termite CLI channel.
  """

  use GenServer

  alias Termite.SSH.Channel
  alias Termite.SSH.Session

  @default_max_sessions 100
  @default_max_channels 1
  @default_terminal_attach_timeout 5_000

  defstruct [:daemon, :entrypoint, :session_supervisor]

  @typedoc "SSH authentication configuration."
  @type auth_option :: :none | [{String.t(), String.t()}]

  @typedoc "Option accepted by `start_link/1`."
  @type option ::
          {:port, pos_integer()}
          | {:ip, :inet.ip_address()}
          | {:auth, auth_option()}
          | {:system_dir, String.t()}
          | {:entrypoint, {module(), keyword()}}
          | {:name, GenServer.name()}
          | {:session_supervisor_name, GenServer.name()}
          | {:max_sessions, pos_integer()}
          | {:max_channels, pos_integer()}
          | {:terminal_attach_timeout, timeout()}

  @doc """
  Starts an SSH server linked to the caller.

  This function is normally invoked by a supervisor. See the module
  documentation for required options and defaults.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Starts and attaches a Termite terminal for `session`.

  Call this from the session entrypoint process. Input, output, resize signals,
  and disconnect signals are routed through the session's SSH channel.
  """
  @spec terminal(Session.t()) :: %Termite.Terminal{}
  def terminal(%Session{} = session) do
    session
    |> Session.terminal_opts()
    |> Termite.Terminal.start()
  end

  @doc """
  Requests that the SSH channel for `session` be closed.

  Session entrypoints should call this after their terminal application exits
  normally. Client disconnects are delivered to the terminal reader as
  `{:signal, :hup}`.
  """
  @spec disconnect(Session.t()) :: term()
  def disconnect(%Session{} = session), do: Session.disconnect(session)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    entrypoint = Keyword.fetch!(opts, :entrypoint)

    {:ok, session_supervisor} =
      DynamicSupervisor.start_link(session_supervisor_opts(opts))

    with {:ok, _apps} <- Application.ensure_all_started(:ssh),
         {:ok, daemon} <- start_daemon_ref(opts, self()) do
      {:ok,
       %__MODULE__{
         daemon: daemon,
         entrypoint: entrypoint,
         session_supervisor: session_supervisor
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:start_session, channel_pid, session}, state) do
    {mod, args} = state.entrypoint
    args = Keyword.put(args, :session, session)

    child_spec = entrypoint_child_spec(mod, args, session)

    case DynamicSupervisor.start_child(state.session_supervisor, child_spec) do
      {:ok, pid} ->
        send(channel_pid, {:session_started, pid})
        {:noreply, state}

      {:error, reason} ->
        send(channel_pid, {:session_start_failed, reason})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: daemon}) do
    :ssh.stop_daemon(daemon)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_daemon_ref(opts, owner) do
    port = Keyword.get(opts, :port, 2222)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    system_dir = opts |> Keyword.fetch!(:system_dir) |> resolve_system_dir!()

    daemon_opts =
      [
        ifaddr: ip,
        system_dir: to_charlist(system_dir),
        max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
        max_channels: Keyword.get(opts, :max_channels, @default_max_channels),
        subsystems: [],
        ssh_cli:
          {Channel,
           [
             owner: owner,
             terminal_attach_timeout:
               Keyword.get(
                 opts,
                 :terminal_attach_timeout,
                 @default_terminal_attach_timeout
               )
           ]}
      ] ++ auth_opts(Keyword.fetch!(opts, :auth))

    :ssh.daemon(port, daemon_opts)
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

  defp auth_opts(user_passwords) when is_list(user_passwords) do
    [
      auth_methods: ~c"password",
      user_passwords:
        Enum.map(user_passwords, fn {username, password} ->
          {to_charlist(username), to_charlist(password)}
        end)
    ]
  end

  defp resolve_system_dir!(dir) do
    File.mkdir_p!(dir)

    case Path.wildcard(Path.join(dir, "ssh_host_*_key")) do
      [] ->
        raise ArgumentError,
              "Termite.SSH requires a system_dir containing ssh_host_*_key files: #{dir}"

      _keys ->
        dir
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
end
