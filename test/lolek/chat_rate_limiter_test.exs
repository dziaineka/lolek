defmodule Lolek.ChatRateLimiterTest do
  use ExUnit.Case, async: true

  setup do
    limiter_name = String.to_atom("#{__MODULE__}.#{System.unique_integer([:positive])}")
    time_agent = start_supervised!({Agent, fn -> 0 end})

    %{limiter_name: limiter_name, time_agent: time_agent}
  end

  test "admits up to configured limit per chat", %{
    limiter_name: limiter_name,
    time_agent: time_agent
  } do
    start_supervised_limiter!(limiter_name, time_agent, limit: 2)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    refute Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
  end

  test "tracks chats independently", %{limiter_name: limiter_name, time_agent: time_agent} do
    start_supervised_limiter!(limiter_name, time_agent, limit: 1)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    refute Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    assert Lolek.ChatRateLimiter.admit?(2, name: limiter_name)
  end

  test "expires attempts outside the rolling window", %{
    limiter_name: limiter_name,
    time_agent: time_agent
  } do
    start_supervised_limiter!(limiter_name, time_agent, limit: 1, window_ms: 60_000)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)

    set_time(time_agent, 60_001)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
  end

  test "rejected attempts keep the chat limited until they expire", %{
    limiter_name: limiter_name,
    time_agent: time_agent
  } do
    start_supervised_limiter!(limiter_name, time_agent, limit: 2, window_ms: 60_000)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
    refute Lolek.ChatRateLimiter.admit?(1, name: limiter_name)

    set_time(time_agent, 59_999)

    refute Lolek.ChatRateLimiter.admit?(1, name: limiter_name)

    set_time(time_agent, 60_001)

    assert Lolek.ChatRateLimiter.admit?(1, name: limiter_name)
  end

  test "rejects invalid limits", %{limiter_name: limiter_name} do
    assert {:error, {:invalid_limit, :limit, 0}} =
             start_limiter(name: limiter_name, limit: 0, window_ms: 60_000)
  end

  test "rejects invalid windows", %{limiter_name: limiter_name} do
    assert {:error, {:invalid_limit, :window_ms, 0}} =
             start_limiter(name: limiter_name, limit: 1, window_ms: 0)
  end

  @spec start_supervised_limiter!(atom(), pid(), keyword()) :: pid()
  defp start_supervised_limiter!(limiter_name, time_agent, opts) do
    opts =
      Keyword.merge(
        [
          name: limiter_name,
          limit: 2,
          window_ms: 60_000,
          time_fun: fn -> Agent.get(time_agent, & &1) end
        ],
        opts
      )

    start_supervised!({Lolek.ChatRateLimiter, opts})
  end

  @spec set_time(pid(), integer()) :: :ok
  defp set_time(time_agent, time) do
    Agent.update(time_agent, fn _ -> time end)
  end

  @spec start_limiter(keyword()) :: GenServer.on_start()
  defp start_limiter(opts) do
    test_pid = self()
    result_ref = make_ref()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {result_ref, Lolek.ChatRateLimiter.start_link(opts)})
    end)

    assert_receive {^result_ref, result}
    result
  end
end
