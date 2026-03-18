defmodule Termite.SSH do
  @moduledoc """
  Start a supervised application session for each client.
  """

  use GenServer

  alias Termite.SSH.Channel
  alias Termite.SSH.Session

  defstruct [:daemon, :entrypoint, :session_supervisor]

  @type auth_option :: :none | [{String.t(), String.t()}]

  @type option ::
          {:port, pos_integer()}
          | {:ip, :inet.ip_address()}
          | {:auth, auth_option()}
          | {:system_dir, String.t()}
          | {:entrypoint, {module(), keyword()}}
          | {:name, GenServer.name()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec terminal(Session.t()) :: Termite.Terminal.t()
  def terminal(%Session{} = session) do
    session
    |> Session.terminal_opts()
    |> Termite.Terminal.start()
  end

  @spec disconnect(Session.t()) :: term()
  def disconnect(%Session{} = session), do: Session.disconnect(session)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    entrypoint = Keyword.fetch!(opts, :entrypoint)
    {:ok, session_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

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
        parallel_login: true,
        ssh_cli: {Channel, [owner: owner]}
      ] ++ auth_opts(Keyword.fetch!(opts, :auth))

    :ssh.daemon(port, daemon_opts)
  end

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
    if function_exported?(mod, :child_spec, 1) do
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
