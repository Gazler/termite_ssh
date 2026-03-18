Code.require_file("helper.exs", __DIR__)

defmodule TermiteSSHTermite do
  def start(terminal) do
    dot_count = 10
    string = String.duplicate(".", dot_count) <> "🪳"

    clear = fn term ->
      term
      |> tap(fn _ -> :timer.sleep(1_000) end)
      |> Termite.Screen.cursor_back(3)
      |> Termite.Screen.delete_chars()
    end

    terminal =
      terminal
      |> Termite.Terminal.write(string)
      |> Termite.Screen.hide_cursor()
      |> Termite.Screen.cursor_back(2)

    terminal = Enum.reduce(1..dot_count, terminal, fn _, term -> clear.(term) end)
    Termite.Screen.show_cursor(terminal)
  end
end

defmodule TermiteSSHTermiteEntrypoint do
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    Task.start_link(fn ->
      session
      |> Termite.SSH.terminal()
      |> TermiteSSHTermite.start()

      Termite.SSH.disconnect(session)
    end)
  end
end

TermiteSSHExample.Helper.start!(
  TermiteSSHTermiteEntrypoint,
  "Termite animation over SSH",
  "examples/termite.exs"
)
