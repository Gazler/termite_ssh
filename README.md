# Termite.SSH

SSH transport for `Termite` applications.

`Termite.SSH` requires an explicit `system_dir` containing server host keys such
as `ssh_host_rsa_key`. You can generate a local key for this repo with:

```bash
mix termite.ssh.gen_host_key
```

That writes a key into `priv/ssh`, which the examples use by default. Pass
`--force` to overwrite an existing key. Override the examples with
`TERMITE_SSH_SYSTEM_DIR` if you want to use a different key directory.

## Run the examples

These examples are all copied from the Termite application and adjusted to use
the SSH adapter.

```bash
mix run examples/demo.exs
mix run examples/colors.exs
mix run examples/snake.exs
mix run examples/termite.exs
```

Each example starts an SSH server on `localhost:2222` by default. Override with
`TERMITE_SSH_PORT`, `TERMITE_SSH_USER`, `TERMITE_SSH_PASSWORD`, and
`TERMITE_SSH_SYSTEM_DIR`.

The examples default to `TERMITE_SSH_NO_AUTH=1`. Set `TERMITE_SSH_NO_AUTH=0` to
require password authentication for local testing.

Then connect with either:

```bash
ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no -p 2222 demo@localhost

# with password auth enabled
TERMITE_SSH_NO_AUTH=0 mix run examples/demo.exs
ssh -p 2222 demo@localhost
```
