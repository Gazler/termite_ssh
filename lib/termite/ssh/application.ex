defmodule Termite.SSH.Application do
  @moduledoc false

  use Application

  @registry Termite.SSH.ServerRegistry
  @server_key :server

  @impl true
  def start(_type, _args) do
    Registry.start_link(keys: :duplicate, name: @registry)
  end

  @impl true
  def prep_stop(state) do
    @registry
    |> Registry.lookup(@server_key)
    |> Enum.each(fn {server, _value} -> Termite.SSH.prepare_shutdown(server) end)

    state
  end

  @doc false
  def register_server do
    if Process.whereis(@registry) do
      case Registry.register(@registry, @server_key, nil) do
        {:ok, _owner} -> :ok
        {:error, {:already_registered, _owner}} -> :ok
      end
    else
      :ok
    end
  end
end
