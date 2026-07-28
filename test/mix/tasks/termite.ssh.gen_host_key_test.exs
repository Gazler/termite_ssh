defmodule Mix.Tasks.Termite.Ssh.GenHostKeyTest do
  use ExUnit.Case, async: false

  import Bitwise

  test "generates a private key with owner-only permissions" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "termite_ssh_key_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.cd!(tmp_dir, fn ->
      Mix.Tasks.Termite.Ssh.GenHostKey.run([])

      path = Path.join([tmp_dir, "priv", "ssh", "ssh_host_rsa_key"])
      assert band(File.stat!(path).mode, 0o777) == 0o600
    end)
  end
end
