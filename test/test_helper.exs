ExUnit.start()

defmodule Termite.SSH.TestKeys do
  def create_system_dir do
    directory = temporary_directory("system")
    File.mkdir_p!(directory)

    {private_key, _public_key} = generate_rsa_keypair()
    write_private_key!(Path.join(directory, "ssh_host_rsa_key"), private_key)
    directory
  end

  def create_user_dir do
    directory = temporary_directory("user")
    File.mkdir_p!(directory)

    {private_key, public_key} = generate_rsa_keypair()
    write_private_key!(Path.join(directory, "id_rsa"), private_key)

    authorized_keys =
      :ssh_file.encode([{public_key, [comment: ~c"termite_ssh test"]}], :auth_keys)

    File.write!(Path.join(directory, "authorized_keys"), authorized_keys)
    directory
  end

  defp temporary_directory(kind) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "termite_ssh_#{kind}_#{unique}")
  end

  defp generate_rsa_keypair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    {:RSAPrivateKey, _version, modulus, public_exponent, _private_exponent, _prime1, _prime2,
     _exponent1, _exponent2, _coefficient, _other_prime_infos} = private_key

    {private_key, {:RSAPublicKey, modulus, public_exponent}}
  end

  defp write_private_key!(path, private_key) do
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
