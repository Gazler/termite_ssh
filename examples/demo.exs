Code.require_file("helper.exs", __DIR__)

defmodule TermiteSSHDemo do
  alias Termite.Screen

  def start(terminal) do
    terminal
    |> Screen.run_escape_sequence(:screen_alt)
    |> Screen.title("Termite Demo")
    |> Screen.progress(:paused, 20)
    |> redraw_and_loop()
  end

  defp redraw_and_loop(state) do
    state |> redraw() |> loop()
  end

  defp loop(state) do
    case Termite.Terminal.poll(state) do
      {:signal, :winch} -> redraw_and_loop(Termite.Terminal.resize(state))
      {:signal, :hup} -> cleanup(state)
      {:data, "\e[A"} -> state |> Screen.run_escape_sequence(:cursor_up, [1]) |> loop()
      {:data, "\e[B"} -> state |> Screen.run_escape_sequence(:cursor_down, [1]) |> loop()
      {:data, "\e[C"} -> state |> Screen.run_escape_sequence(:cursor_forward, [1]) |> loop()
      {:data, "\e[D"} -> state |> Screen.run_escape_sequence(:cursor_back, [1]) |> loop()
      {:data, "q"} -> cleanup(state)
      {:data, "r"} -> redraw_and_loop(state)
      _ -> loop(state)
    end
  end

  defp cleanup(state) do
    state
    |> Screen.run_escape_sequence(:screen_alt_exit)
    |> Screen.run_escape_sequence(:screen_clear)
    |> Screen.progress(:clear)
  end

  defp panel(state, str) do
    state = Screen.write(state, "┌" <> String.duplicate("─", state.size.width - 2) <> "┐")

    state =
      Enum.reduce(1..(state.size.height - 2), state, fn _, acc ->
        Screen.write(acc, "│" <> String.duplicate(" ", state.size.width - 2) <> "│")
      end)

    state = Screen.write(state, "└" <> String.duplicate("─", state.size.width - 2) <> "┘")

    state
    |> Screen.run_escape_sequence(:cursor_move, [3, 0])
    |> Screen.write(str)
    |> Screen.run_escape_sequence(:cursor_move, [3, 3])
  end

  defp redraw(state) do
    state
    |> Screen.run_escape_sequence(:cursor_move, [0, 0])
    |> Screen.run_escape_sequence(:screen_clear)
    |> panel("Size: #{state.size.width}x#{state.size.height}")
    |> Screen.write("This is a simple demo")
    |> Screen.run_escape_sequence(:cursor_next_line, [1])
    |> Screen.run_escape_sequence(:cursor_forward, [2])
    |> Screen.write("Press q to Exit")
  end
end

defmodule TermiteSSHDemoEntrypoint do
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    Task.start_link(fn ->
      session
      |> Termite.SSH.terminal()
      |> TermiteSSHDemo.start()

      Termite.SSH.disconnect(session)
    end)
  end
end

TermiteSSHExample.Helper.start!(
  TermiteSSHDemoEntrypoint,
  "Termite demo over SSH",
  "examples/demo.exs"
)
