defmodule Lolek.ProcessingDeadline do
  @moduledoc """
  Enforces one monotonic deadline across all stages of a media request.
  """

  @deadline_key {__MODULE__, :deadline}
  @command_state_key {__MODULE__, :command_state}
  @cancel_message {__MODULE__, :cancel}

  @type deadline_error :: {:error, :processing_deadline_exceeded}

  @doc "Runs work within the timeout and cleans up any active command before returning."
  @spec run((-> term()), non_neg_integer()) :: term() | deadline_error()
  def run(_fun, timeout) when timeout <= 0, do: {:error, :processing_deadline_exceeded}

  def run(fun, timeout) when is_function(fun, 0) do
    # Note: this assumes a single command in flight.
    # Extend once we consider parallel execution.
    command_state = :atomics.new(1, [])

    task =
      Task.async(fn ->
        Process.put(@deadline_key, System.monotonic_time(:millisecond) + timeout)
        Process.put(@command_state_key, command_state)
        fun.()
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        stop_task(task, :atomics.get(command_state, 1))

        {:error, :processing_deadline_exceeded}
    end
  end

  @doc false
  @spec with_command(non_neg_integer(), (-> result)) :: result when result: term()
  def with_command(kill_timeout, fun) when is_function(fun, 0) do
    case Process.get(@command_state_key) do
      nil ->
        fun.()

      command_state ->
        # erlexec gets 1s to reap pid. Grant additional 1s here.
        :atomics.put(command_state, 1, :timer.seconds(kill_timeout + 2))

        try do
          fun.()
        after
          :atomics.put(command_state, 1, 0)
        end
    end
  end

  @doc false
  @spec cancellation_message() :: term()
  def cancellation_message, do: @cancel_message

  @doc "Returns a command timeout capped by the active processing deadline."
  @spec limit_timeout(timeout()) :: timeout()
  def limit_timeout(timeout) do
    case Process.get(@deadline_key) do
      nil -> timeout
      deadline -> min_timeout(timeout, remaining_timeout(deadline))
    end
  end

  @doc "Returns whether the active processing deadline has elapsed."
  @spec expired?() :: boolean()
  def expired? do
    case Process.get(@deadline_key) do
      nil -> false
      deadline -> remaining_timeout(deadline) == 0
    end
  end

  @spec stop_task(Task.t(), non_neg_integer()) :: :ok
  defp stop_task(task, cleanup_timeout) when cleanup_timeout > 0 do
    # Let it stop the pid before we murder the worker.
    send(task.pid, @cancel_message)

    if Task.yield(task, cleanup_timeout) == nil do
      Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp stop_task(task, 0) do
    # Last resort. :(
    # Some lingering resources can be left behind, e.g. local upload files. SAD.
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  @spec min_timeout(timeout(), non_neg_integer()) :: non_neg_integer()
  defp min_timeout(:infinity, remaining), do: remaining
  defp min_timeout(timeout, remaining), do: min(timeout, remaining)

  @spec remaining_timeout(integer()) :: non_neg_integer()
  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
