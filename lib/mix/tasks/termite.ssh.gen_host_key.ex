defmodule Mix.Tasks.Termite.Ssh.GenHostKey do
  @moduledoc """
  Generates an RSA SSH host key for local Termite.SSH development.

      mix termite.ssh.gen_host_key

  The private and public keys are written to `priv/ssh`. Existing keys are
  preserved unless `--force` is supplied:

      mix termite.ssh.gen_host_key --force

  The private key is created with owner-only (`0600`) permissions. Production
  deployments should provision and protect host keys independently of the
  application release.
  """

  use Mix.Task

  @shortdoc "Generate an SSH host key in priv/ssh"

  @doc false
  @impl true
  def run(args) do
    ensure_public_key_started!()

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: [force: :boolean])

    path = Path.join([File.cwd!(), "priv", "ssh", "ssh_host_rsa_key"])
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    force = opts[:force] == true

    if File.exists?(path) and !force do
      Mix.raise("SSH host key already exists at #{path}. Use --force to overwrite it.")
    end

    if force do
      File.rm(path)
      File.rm(path <> ".pub")
    end

    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = public_key(private_key)

    File.write!(path, encode_pem(:RSAPrivateKey, private_key))
    File.chmod!(path, 0o600)
    File.write!(path <> ".pub", encode_pem(:RSAPublicKey, public_key))

    Mix.shell().info("Generated SSH host key at #{path}")
  end

  defp ensure_public_key_started! do
    case Application.ensure_all_started(:public_key) do
      {:ok, _applications} ->
        :ok

      {:error, {application, reason}} ->
        Mix.raise(
          "could not start #{application} while generating an SSH host key: #{inspect(reason)}"
        )
    end
  end

  defp public_key(
         {:RSAPrivateKey, _version, modulus, public_exponent, _private_exponent, _prime1, _prime2,
          _exponent1, _exponent2, _coefficient, _other_prime_infos}
       ) do
    {:RSAPublicKey, modulus, public_exponent}
  end

  defp encode_pem(type, key) do
    :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])
  end
end
