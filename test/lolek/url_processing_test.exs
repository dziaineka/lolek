defmodule Lolek.UrlProcessingTest do
  use ExUnit.Case, async: false

  setup do
    registry_name = String.to_atom("#{__MODULE__}.#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: registry_name})
    %{registry_name: registry_name}
  end

  test "serializes processing for the same url", %{registry_name: registry_name} do
    test_pid = self()
    url = "https://example.com/reel/serialized"

    owner_task =
      Task.async(fn ->
        Lolek.UrlProcessing.process(
          url,
          fn ->
            send(test_pid, :owner_started)

            receive do
              :release_owner -> {:ok, :owner_done}
            end
          end,
          registry: registry_name,
          timeout: 100
        )
      end)

    assert_receive :owner_started

    waiter_task =
      Task.async(fn ->
        Lolek.UrlProcessing.process(
          url,
          fn ->
            send(test_pid, :waiter_started)
            {:ok, :waiter_done}
          end,
          registry: registry_name,
          timeout: 1_000
        )
      end)

    refute_receive :waiter_started, 100

    send(owner_task.pid, :release_owner)

    assert {:ok, :owner_done} = Task.await(owner_task)
    assert_receive :waiter_started
    assert {:ok, :waiter_done} = Task.await(waiter_task)
  end

  test "times out while waiting for active owner", %{registry_name: registry_name} do
    test_pid = self()
    url = "https://example.com/reel/timeout"

    owner_task =
      Task.async(fn ->
        Lolek.UrlProcessing.process(
          url,
          fn ->
            send(test_pid, :owner_started)

            receive do
              :release_owner -> {:ok, :owner_done}
            end
          end,
          registry: registry_name,
          timeout: 100
        )
      end)

    assert_receive :owner_started

    assert {:error, :url_processing_timeout} =
             Lolek.UrlProcessing.process(
               url,
               fn -> {:ok, :waiter_done} end,
               registry: registry_name,
               timeout: 50
             )

    send(owner_task.pid, :release_owner)
    assert {:ok, :owner_done} = Task.await(owner_task)
  end

  test "allows different urls to process concurrently", %{registry_name: registry_name} do
    test_pid = self()

    first_task =
      Task.async(fn ->
        Lolek.UrlProcessing.process(
          "https://example.com/reel/first",
          fn ->
            send(test_pid, :first_started)
            {:ok, :first_done}
          end,
          registry: registry_name,
          timeout: 100
        )
      end)

    second_task =
      Task.async(fn ->
        Lolek.UrlProcessing.process(
          "https://example.com/reel/second",
          fn ->
            send(test_pid, :second_started)
            {:ok, :second_done}
          end,
          registry: registry_name,
          timeout: 100
        )
      end)

    assert_receive :first_started
    assert_receive :second_started
    assert {:ok, :first_done} = Task.await(first_task)
    assert {:ok, :second_done} = Task.await(second_task)
  end
end
