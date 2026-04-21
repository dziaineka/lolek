defmodule Lolek.UrlProcessing do
  @moduledoc """
  This module serializes concurrent processing of the same URL.
  """

  @registry Lolek.UrlProcessingRegistry
  @default_wait_timeout :timer.minutes(15)
  @retry_interval 100

  @type process_result :: {:ok, term()} | {:error, term()}

  @spec process(String.t(), (-> process_result())) :: process_result()
  def process(url, fun) when is_function(fun, 0) do
    process(url, fun, [])
  end

  @spec process(String.t(), (-> process_result()), keyword()) :: process_result()
  def process(url, fun, opts) when is_function(fun, 0) do
    key = Lolek.Url.to_folder_name(url)
    registry = Keyword.get(opts, :registry, @registry)
    timeout = Keyword.get(opts, :timeout, @default_wait_timeout)

    acquire_or_wait(registry, key, fun, timeout)
  end

  @spec acquire_or_wait(Registry.registry(), String.t(), (-> process_result()), timeout()) ::
          process_result()
  defp acquire_or_wait(registry, key, fun, timeout) do
    case Registry.register(registry, key, nil) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(registry, key)
        end

      {:error, {:already_registered, owner_pid}} ->
        wait_for_owner_and_retry(registry, key, owner_pid, fun, timeout)
    end
  end

  @spec wait_for_owner_and_retry(
          Registry.registry(),
          String.t(),
          pid(),
          (-> process_result()),
          timeout()
        ) :: process_result()
  defp wait_for_owner_and_retry(registry, key, owner_pid, fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout_in_milliseconds(timeout)
    monitor_ref = Process.monitor(owner_pid)

    result = wait_until_available(registry, key, owner_pid, fun, deadline, monitor_ref)
    Process.demonitor(monitor_ref, [:flush])
    result
  end

  @spec wait_until_available(
          Registry.registry(),
          String.t(),
          pid(),
          (-> process_result()),
          integer(),
          reference()
        ) :: process_result()
  defp wait_until_available(registry, key, owner_pid, fun, deadline, monitor_ref) do
    remaining_timeout = deadline - System.monotonic_time(:millisecond)

    receive do
      {:DOWN, ^monitor_ref, :process, ^owner_pid, _reason} ->
        acquire_or_wait(registry, key, fun, max(remaining_timeout, 0))
    after
      min(@retry_interval, max(remaining_timeout, 0)) ->
        if remaining_timeout <= 0 do
          {:error, :url_processing_timeout}
        else
          case Registry.lookup(registry, key) do
            [] ->
              acquire_or_wait(registry, key, fun, remaining_timeout)

            [{^owner_pid, _value}] ->
              wait_until_available(registry, key, owner_pid, fun, deadline, monitor_ref)

            [{next_owner_pid, _value}] ->
              wait_for_owner_and_retry(registry, key, next_owner_pid, fun, remaining_timeout)
          end
        end
    end
  end

  @spec timeout_in_milliseconds(timeout()) :: non_neg_integer()
  defp timeout_in_milliseconds(:infinity), do: 365 * 24 * 60 * 60 * 1000
  defp timeout_in_milliseconds(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
end
