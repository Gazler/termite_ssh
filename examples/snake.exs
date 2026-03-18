Code.require_file("helper.exs", __DIR__)

defmodule TermiteSSHSnake do
  alias Termite.Screen

  def start(terminal) do
    term =
      terminal
      |> Screen.run_escape_sequence(:screen_alt)
      |> Screen.run_escape_sequence(:cursor_hide)

    %{
      term: term,
      size: %{width: 25, height: 15},
      direction: :right,
      path: [{7, 10}, {8, 10}, {9, 10}, {10, 10}],
      food: nil
    }
    |> generate_food()
    |> redraw_and_loop()
  end

  defp generate_food(state) do
    x = :rand.uniform(state.size.width - 2) + 1
    y = :rand.uniform(state.size.height - 2) + 1

    if {x, y} in state.path do
      generate_food(state)
    else
      %{state | food: {x, y}}
    end
  end

  defp redraw_and_loop(state) do
    state |> redraw() |> loop()
  end

  defp loop(%{term: term} = state) do
    case draw_snake(state) do
      {:halt, term} ->
        term

      state ->
        case Termite.Terminal.poll(term, 100) do
          {:signal, :winch} -> redraw_and_loop(%{state | term: Termite.Terminal.resize(term)})
          {:signal, :hup} -> cleanup(term)
          {:data, "\e[A"} -> change_direction(state, :up) |> loop()
          {:data, "\e[B"} -> change_direction(state, :down) |> loop()
          {:data, "\e[C"} -> change_direction(state, :right) |> loop()
          {:data, "\e[D"} -> change_direction(state, :left) |> loop()
          {:data, "q"} -> cleanup(term)
          :timeout -> loop(state)
          _ -> loop(state)
        end
    end
  end

  defp change_direction(%{direction: :left} = state, dir) when dir in [:left, :right], do: state
  defp change_direction(%{direction: :right} = state, dir) when dir in [:left, :right], do: state
  defp change_direction(%{direction: :up} = state, dir) when dir in [:up, :down], do: state
  defp change_direction(%{direction: :down} = state, dir) when dir in [:up, :down], do: state
  defp change_direction(state, dir), do: %{state | direction: dir}

  defp cleanup(term) do
    term
    |> Screen.run_escape_sequence(:cursor_show)
    |> Screen.run_escape_sequence(:screen_alt_exit)
    |> Screen.run_escape_sequence(:screen_clear)
  end

  defp game_panel(term, state) do
    term =
      term
      |> Screen.write("┌" <> String.duplicate("─", state.size.width * 2 - 2) <> "┐")
      |> Screen.run_escape_sequence(:cursor_next_line, [1])

    term =
      Enum.reduce(1..(state.size.height - 2), term, fn _, acc ->
        acc
        |> Screen.write("│" <> String.duplicate(" ", state.size.width * 2 - 2) <> "│")
        |> Screen.run_escape_sequence(:cursor_next_line, [1])
      end)

    term
    |> Screen.write("└" <> String.duplicate("─", state.size.width * 2 - 2))
    |> Screen.write("┘")
  end

  defp redraw(state) do
    term =
      state.term
      |> Screen.run_escape_sequence(:cursor_move, [0, 0])
      |> Screen.run_escape_sequence(:screen_clear)
      |> game_panel(state)

    %{state | term: term}
  end

  defp draw_food(state) do
    {food_x, food_y} = state.food

    term =
      state.term
      |> Screen.run_escape_sequence(:cursor_move, [food_x * 2, food_y])
      |> Screen.write("*")

    %{state | term: term}
  end

  defp draw_snake(state) do
    %{term: term, path: path, direction: direction} = state
    {cur_x, cur_y} = List.last(path)
    {tail_x, tail_y} = hd(path)

    term =
      term
      |> Screen.run_escape_sequence(:cursor_move, [tail_x * 2, tail_y])
      |> Screen.write("  ")

    new_point =
      case direction do
        :right -> {cur_x + 1, cur_y}
        :left -> {cur_x - 1, cur_y}
        :up -> {cur_x, cur_y - 1}
        :down -> {cur_x, cur_y + 1}
      end

    {new_x, new_y} = new_point

    wall_collision? =
      new_x == 0 || new_x == state.size.width || new_y == 1 || new_y == state.size.height

    tail_collision? = new_point in state.path

    state =
      cond do
        new_point == state.food -> generate_food(%{state | path: path ++ [new_point]})
        wall_collision? || tail_collision? -> %{state | path: path}
        true -> %{state | path: tl(path) ++ [new_point]}
      end

    if wall_collision? || tail_collision? do
      {:halt,
       term
       |> cleanup()
       |> Termite.Screen.write("Game over\r\n")}
    else
      term = Screen.write(term, IO.ANSI.inverse())

      term =
        Enum.reduce(state.path, term, fn {x, y}, acc ->
          acc
          |> Screen.run_escape_sequence(:cursor_move, [x * 2, y])
          |> Screen.write("  ")
        end)

      term = Screen.write(term, IO.ANSI.reset())
      draw_food(%{state | term: term})
    end
  end
end

defmodule TermiteSSHSnakeEntrypoint do
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    Task.start_link(fn ->
      session
      |> Termite.SSH.terminal()
      |> TermiteSSHSnake.start()

      Termite.SSH.disconnect(session)
    end)
  end
end

TermiteSSHExample.Helper.start!(
  TermiteSSHSnakeEntrypoint,
  "Termite snake over SSH",
  "examples/snake.exs"
)
