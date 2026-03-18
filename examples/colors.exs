Code.require_file("helper.exs", __DIR__)

defmodule TermiteSSHColors do
  def start(term) do
    term
    |> draw()
    |> loop()
  end

  defp loop(term) do
    case Termite.Terminal.poll(term) do
      {:signal, :winch} ->
        term |> Termite.Terminal.resize() |> draw() |> loop()

      {:signal, :hup} ->
        term

      {:data, "q"} ->
        term

      _ ->
        loop(term)
    end
  end

  defp newline(str, i, i), do: str <> "\n"
  defp newline(str, _i, _limit), do: str

  defp color_block(foreground, background, padding \\ 3) do
    Termite.Style.ansi256()
    |> Termite.Style.background(background)
    |> Termite.Style.foreground(foreground)
    |> Termite.Style.render_to_string(
      " #{String.pad_leading(to_string(background), padding, " ")}   "
    )
  end

  defp draw(term) do
    term = Termite.Screen.run_escape_sequence(term, :screen_clear)
    str = Termite.Style.bold() |> Termite.Style.render_to_string("Basic ANSI Colors\n")
    term = Termite.Screen.write(term, str)

    term =
      Enum.reduce(0..15, term, fn i, acc ->
        foreground = if i < 5, do: 7, else: 0
        str = color_block(foreground, i, 2)
        Termite.Screen.write(acc, newline(str, i, 7))
      end)

    str = Termite.Style.bold() |> Termite.Style.render_to_string("\n\nExtended ANSI Colors\n")
    term = Termite.Screen.write(term, str)

    term =
      Enum.reduce(16..231, term, fn i, acc ->
        foreground = if i < 28, do: 7, else: 0
        str = color_block(foreground, i)
        Termite.Screen.write(acc, newline(str, rem(i - 16, 6), 5))
      end)

    str = Termite.Style.bold() |> Termite.Style.render_to_string("\n\nExtended ANSI Grayscale\n")
    term = Termite.Screen.write(term, str)

    term =
      Enum.reduce(232..255, term, fn i, acc ->
        foreground = if i < 244, do: 7, else: 0
        str = color_block(foreground, i)
        Termite.Screen.write(acc, newline(str, rem(i - 232, 6), 5))
      end)

    term
    |> Termite.Screen.write("\n\nPress q to quit")
    |> Termite.Screen.write("\n")
  end
end

defmodule TermiteSSHColorsEntrypoint do
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    Task.start_link(fn ->
      session
      |> Termite.SSH.terminal()
      |> TermiteSSHColors.start()

      Termite.SSH.disconnect(session)
    end)
  end
end

TermiteSSHExample.Helper.start!(
  TermiteSSHColorsEntrypoint,
  "Termite colors over SSH",
  "examples/colors.exs"
)
