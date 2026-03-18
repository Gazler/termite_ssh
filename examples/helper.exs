defmodule TermiteSSHExample.Helper do
  def start!(entrypoint, example_name, script_path) do
    port = System.get_env("TERMITE_SSH_PORT", "2222") |> String.to_integer()
    username = System.get_env("TERMITE_SSH_USER", "demo")
    password = System.get_env("TERMITE_SSH_PASSWORD", "demo")

    no_auth? =
      case System.get_env("TERMITE_SSH_NO_AUTH") do
        nil -> true
        value -> value in ["1", "true", "TRUE"]
      end
    system_dir = System.get_env("TERMITE_SSH_SYSTEM_DIR") || Path.expand("../priv/ssh", __DIR__)

    case Termite.SSH.start_link(
           port: port,
           auth: auth_opts(no_auth?, username, password),
           system_dir: system_dir,
           entrypoint: {entrypoint, []}
         ) do
      {:ok, _daemon} ->
        IO.puts(connection_message(example_name, port, username, password, no_auth?))
        Process.sleep(:infinity)

      {:error, :eaddrinuse} ->
        raise """
        SSH example could not start because port #{port} is already in use.

        Try:
          TERMITE_SSH_PORT=2230 mix run #{script_path}
        """

      {:error, reason} ->
        raise "SSH example failed to start: #{inspect(reason)}"
    end
  end

  defp auth_opts(true, _username, _password), do: :none
  defp auth_opts(false, username, password), do: [{username, password}]

  defp connection_message(example_name, port, username, _password, true) do
    """
    Starting #{example_name} on localhost:#{port}

    Connect with:
      ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no -p #{port} #{username}@localhost

    Authentication:
      disabled
    """
  end

  defp connection_message(example_name, port, username, password, false) do
    """
    Starting #{example_name} on localhost:#{port}

    Connect with:
      ssh -p #{port} #{username}@localhost

    Password:
      #{password}
    """
  end
end
