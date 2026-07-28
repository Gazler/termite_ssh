defmodule Termite.SSH.KeyCallback do
  @moduledoc false

  @behaviour :ssh_server_key_api

  @impl :ssh_server_key_api
  def host_key(algorithm, options), do: :ssh_file.host_key(algorithm, options)

  @impl :ssh_server_key_api
  def is_auth_key(key, username, options) do
    case key_callback_option(options, :verifier) do
      verifier when is_function(verifier, 2) ->
        verifier.(IO.chardata_to_string(username), key) == true

      _other ->
        authorize_from_file(key, username, options)
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp authorize_from_file(key, username, options) do
    with user_dirs when is_map(user_dirs) <- key_callback_option(options, :user_dirs),
         {:ok, directory} <- Map.fetch(user_dirs, username) do
      options
      |> Keyword.put(:user_dir, directory)
      |> then(&:ssh_file.is_auth_key(key, username, &1))
    else
      _ -> false
    end
  end

  defp key_callback_option(options, key) do
    options |> Keyword.get(:key_cb_private, []) |> Keyword.get(key)
  end
end
