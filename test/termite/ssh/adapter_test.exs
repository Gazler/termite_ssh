defmodule Termite.SSH.AdapterTest do
  use ExUnit.Case, async: true

  alias Termite.SSH.Adapter

  test "start attaches the terminal to the requested reader target" do
    parent = self()

    channel =
      spawn_link(fn ->
        receive do
          {:terminal_request, from, ref, {:attach_terminal, target, reader_ref}} ->
            send(parent, {:attached, target, reader_ref})
            send(from, {:terminal_reply, ref, :ok})
        end
      end)

    {:ok, terminal} = Adapter.start(channel_pid: channel, reader_target: self())

    assert_receive {:attached, ^parent, reader_ref}
    assert terminal.reader_ref == reader_ref
    assert {:ok, ^reader_ref} = Adapter.reader(terminal)
  end

  test "write normalizes newlines before sending" do
    parent = self()

    channel =
      spawn_link(fn ->
        receive do
          {:terminal_request, from, ref, {:write, data}} ->
            send(parent, {:written, data})
            send(from, {:terminal_reply, ref, :ok})
        end
      end)

    terminal = %Adapter{channel_pid: channel, reader_ref: make_ref()}
    assert {:ok, ^terminal} = Adapter.write(terminal, "a\nb\r\nc")
    assert_receive {:written, "a\r\nb\r\nc"}
  end

  test "write becomes a no-op when the channel is closed" do
    channel = spawn_link(fn -> :ok end)
    terminal = %Adapter{channel_pid: channel, reader_ref: make_ref()}
    assert {:ok, ^terminal} = Adapter.write(terminal, "hello")
  end

  test "resize falls back when the channel is closed" do
    channel = spawn_link(fn -> :ok end)
    terminal = %Adapter{channel_pid: channel, reader_ref: make_ref()}
    assert %{width: 80, height: 24} = Adapter.resize(terminal)
  end
end
