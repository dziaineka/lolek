defmodule Lolek.ProcessingLimiterTest do
  use ExUnit.Case, async: true

  setup do
    limiter_name = String.to_atom("#{__MODULE__}.#{System.unique_integer([:positive])}")
    %{limiter_name: limiter_name}
  end

  test "limits globally across chats", %{limiter_name: limiter_name} do
    start_supervised!(
      {Lolek.ProcessingLimiter, name: limiter_name, global_limit: 1, per_chat_limit: 1}
    )

    test_pid = self()

    first_task =
      Task.async(fn ->
        Lolek.ProcessingLimiter.with_limit(
          1,
          fn ->
            send(test_pid, :first_started)

            receive do
              :release_first -> {:ok, :first_done}
            end
          end,
          name: limiter_name
        )
      end)

    assert_receive :first_started

    second_task =
      Task.async(fn ->
        Lolek.ProcessingLimiter.with_limit(
          2,
          fn ->
            send(test_pid, :second_started)
            {:ok, :second_done}
          end,
          name: limiter_name
        )
      end)

    refute_receive :second_started, 100

    send(first_task.pid, :release_first)

    assert_receive :second_started
    assert {:ok, :first_done} = Task.await(first_task)
    assert {:ok, :second_done} = Task.await(second_task)
  end

  test "limits work per chat while allowing other chats to proceed", %{limiter_name: limiter_name} do
    start_supervised!(
      {Lolek.ProcessingLimiter, name: limiter_name, global_limit: 2, per_chat_limit: 1}
    )

    test_pid = self()

    first_task =
      Task.async(fn ->
        Lolek.ProcessingLimiter.with_limit(
          1,
          fn ->
            send(test_pid, :first_started)

            receive do
              :release_first -> {:ok, :first_done}
            end
          end,
          name: limiter_name
        )
      end)

    assert_receive :first_started

    same_chat_task =
      Task.async(fn ->
        Lolek.ProcessingLimiter.with_limit(
          1,
          fn ->
            send(test_pid, :same_chat_started)
            {:ok, :same_chat_done}
          end,
          name: limiter_name
        )
      end)

    other_chat_task =
      Task.async(fn ->
        Lolek.ProcessingLimiter.with_limit(
          2,
          fn ->
            send(test_pid, :other_chat_started)
            {:ok, :other_chat_done}
          end,
          name: limiter_name
        )
      end)

    assert_receive :other_chat_started
    refute_receive :same_chat_started, 100

    send(first_task.pid, :release_first)

    assert_receive :same_chat_started
    assert {:ok, :first_done} = Task.await(first_task)
    assert {:ok, :same_chat_done} = Task.await(same_chat_task)
    assert {:ok, :other_chat_done} = Task.await(other_chat_task)
  end

  test "releases capacity when limited function returns an error", %{limiter_name: limiter_name} do
    start_supervised!(
      {Lolek.ProcessingLimiter, name: limiter_name, global_limit: 1, per_chat_limit: 1}
    )

    assert {:error, :failed} =
             Lolek.ProcessingLimiter.with_limit(1, fn -> {:error, :failed} end,
               name: limiter_name
             )

    assert {:ok, :after_error} =
             Lolek.ProcessingLimiter.with_limit(1, fn -> {:ok, :after_error} end,
               name: limiter_name
             )
  end

  test "releases capacity when limited function raises", %{limiter_name: limiter_name} do
    start_supervised!(
      {Lolek.ProcessingLimiter, name: limiter_name, global_limit: 1, per_chat_limit: 1}
    )

    assert_raise RuntimeError, "boom", fn ->
      Lolek.ProcessingLimiter.with_limit(1, fn -> raise "boom" end, name: limiter_name)
    end

    assert {:ok, :after_raise} =
             Lolek.ProcessingLimiter.with_limit(1, fn -> {:ok, :after_raise} end,
               name: limiter_name
             )
  end

  test "rejects invalid limits", %{limiter_name: limiter_name} do
    assert {:error, {:invalid_limit, :global_limit, 0}} =
             start_limiter(
               name: limiter_name,
               global_limit: 0,
               per_chat_limit: 1
             )
  end

  test "rejects per-chat limit above global limit", %{limiter_name: limiter_name} do
    assert {:error, {:per_chat_limit_exceeds_global_limit, 2, 1}} =
             start_limiter(
               name: limiter_name,
               global_limit: 1,
               per_chat_limit: 2
             )
  end

  @spec start_limiter(keyword()) :: GenServer.on_start()
  defp start_limiter(opts) do
    test_pid = self()
    result_ref = make_ref()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {result_ref, Lolek.ProcessingLimiter.start_link(opts)})
    end)

    assert_receive {^result_ref, result}
    result
  end
end
