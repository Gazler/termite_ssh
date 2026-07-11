# Termite.SSH

SSH transport for `Termite` applications.

## Installation

Add `termite_ssh` to your dependencies:

```elixir
def deps do
  [
    {:termite_ssh, "~> 0.1.0"}
  ]
end
```

Add `Termite.SSH` to your application's supervision tree to start the SSH
listener. Its module documentation describes the required options, session
entrypoint contract, resource limits, and security considerations.

## Host key

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

For resource safety, each server defaults to 100 simultaneous SSH sessions,
one active channel per connection, and a five-second deadline for the Termite
terminal to attach after a shell request. Override these with `:max_sessions`,
`:max_channels`, and `:terminal_attach_timeout` when starting `Termite.SSH`.
SFTP and other SSH subsystems are disabled.

Then connect with either:

```bash
ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no -p 2222 demo@localhost

# with password auth enabled
TERMITE_SSH_NO_AUTH=0 mix run examples/demo.exs
ssh -p 2222 demo@localhost
```
