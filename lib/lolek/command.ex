defmodule Lolek.Command do
  @moduledoc """
  Runs external commands without invoking a shell.
  """

  @default_kill_timeout_seconds 5

  @type output_chunk :: {:stdout | :stderr, [binary()]}
  @type output :: [output_chunk()]
  @type result :: {:ok, output()} | {:error, term()}

  @spec run(String.t(), [String.t()]) :: result()
  @spec run(String.t(), [String.t()], [term()]) :: result()
  def run(executable, args, options \\ []) do
    {timeout, options} = pop_option(options, :timeout, :infinity)
    timeout = Lolek.ProcessingDeadline.limit_timeout(timeout)
    {kill_timeout, options} = pop_option(options, :kill_timeout, @default_kill_timeout_seconds)

    with false <- Lolek.ProcessingDeadline.expired?(),
         executable_path when is_binary(executable_path) <- System.find_executable(executable) do
      Lolek.ProcessingDeadline.with_command(kill_timeout, fn ->
        run_executable(executable, executable_path, args, options, timeout, kill_timeout)
      end)
    else
      true -> {:error, :processing_deadline_exceeded}
      nil -> {:error, "#{executable} executable was not found"}
    end
  end

  @spec run_executable(
          String.t(),
          String.t(),
          [String.t()],
          [term()],
          timeout(),
          non_neg_integer()
        ) ::
          result()
  defp run_executable(executable, executable_path, args, options, timeout, kill_timeout) do
    exec_options = prepare_exec_options(options, kill_timeout)

    case executable_path |> exec_argv(args) |> :exec.run(exec_options) do
      {:ok, pid, os_pid} -> collect_output(executable, pid, os_pid, timeout, kill_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec exec_argv(String.t(), [String.t()]) :: [charlist(), ...]
  defp exec_argv(executable_path, args) do
    [String.to_charlist(executable_path) | Enum.map(args, &String.to_charlist/1)]
  end

  @spec pop_option([term()], atom(), term()) :: {term(), [term()]}
  defp pop_option(options, key, default) do
    {value, options} =
      Enum.reduce(options, {default, []}, fn
        {^key, option_value}, {_value, options} -> {option_value, options}
        option, {value, options} -> {value, [option | options]}
      end)

    {value, Enum.reverse(options)}
  end

  @spec prepare_exec_options([term()], non_neg_integer()) :: [term()]
  defp prepare_exec_options(options, kill_timeout) do
    options
    |> Enum.reject(&(&1 == :sync or &1 == :monitor))
    |> then(
      &[:monitor, {:group, 0}, :kill_group, {:kill_timeout, kill_timeout}, :stdout, :stderr | &1]
    )
  end

  @spec collect_output(String.t(), pid(), integer(), timeout(), non_neg_integer()) :: result()
  defp collect_output(executable, pid, os_pid, timeout, kill_timeout) do
    deadline = deadline(timeout)

    collect_output(executable, pid, os_pid, timeout, kill_timeout, deadline, %{
      stdout: [],
      stderr: []
    })
  end

  @spec collect_output(
          String.t(),
          pid(),
          integer(),
          timeout(),
          non_neg_integer(),
          integer() | :infinity,
          %{stdout: [binary()], stderr: [binary()]}
        ) :: result()
  defp collect_output(executable, pid, os_pid, timeout, kill_timeout, deadline, output) do
    cancel_message = Lolek.ProcessingDeadline.cancellation_message()

    receive do
      {:stdout, ^os_pid, data} ->
        output = Map.update!(output, :stdout, &[data | &1])
        collect_output(executable, pid, os_pid, timeout, kill_timeout, deadline, output)

      {:stderr, ^os_pid, data} ->
        output = Map.update!(output, :stderr, &[data | &1])
        collect_output(executable, pid, os_pid, timeout, kill_timeout, deadline, output)

      {:DOWN, ^os_pid, :process, ^pid, :normal} ->
        {:ok, output_to_keyword(output)}

      {:DOWN, ^os_pid, :process, ^pid, reason} ->
        {:error, normalize_exit_reason(reason, output_to_keyword(output))}

      ^cancel_message ->
        # Grant erlexec another second to reap a killed pid.
        _ = :exec.stop_and_wait(pid, (kill_timeout + 1) * 1000)
        {:error, :processing_deadline_exceeded}
    after
      remaining_timeout(deadline) ->
        _ = :exec.stop_and_wait(pid, (kill_timeout + 1) * 1000)
        {:error, {:command_timeout, executable, timeout}}
    end
  end

  @spec deadline(timeout()) :: integer() | :infinity
  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  @spec remaining_timeout(integer() | :infinity) :: timeout()
  defp remaining_timeout(:infinity), do: :infinity

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  @spec output_to_keyword(%{stdout: [binary()], stderr: [binary()]}) :: output()
  defp output_to_keyword(output) do
    output
    |> Enum.map(fn {key, chunks} -> {key, Enum.reverse(chunks)} end)
    |> Enum.reject(fn {_key, chunks} -> chunks == [] end)
  end

  @spec normalize_exit_reason(term(), output()) :: output() | term()
  defp normalize_exit_reason({:exit_status, status}, output) do
    normalize_status(status, output)
  end

  defp normalize_exit_reason({:status, status}, output) do
    normalize_status(status, output)
  end

  defp normalize_exit_reason(reason, _output), do: reason

  @spec normalize_status(integer(), output()) :: output()
  defp normalize_status(status, output) do
    status_reason =
      case :exec.status(status) do
        {:status, exit_status} -> [exit_status: exit_status]
        {:signal, signal, core?} -> [signal: signal, core_dump: core?]
      end

    Keyword.merge(output, status_reason, fn _k, output_value, _status_value ->
      output_value
    end)
  end
end
