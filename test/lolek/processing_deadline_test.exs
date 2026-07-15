defmodule Lolek.ProcessingDeadlineTest do
  use ExUnit.Case, async: true

  test "returns work completed before the deadline" do
    assert {:ok, :done} = Lolek.ProcessingDeadline.run(fn -> {:ok, :done} end, 100)
  end

  test "stops work at the overall deadline" do
    test_pid = self()

    assert {:error, :processing_deadline_exceeded} =
             Lolek.ProcessingDeadline.run(
               fn ->
                 Process.sleep(100)
                 send(test_pid, :posted)
               end,
               10
             )

    refute_receive :posted, 150
  end

  test "caps every command timeout by the same deadline" do
    test_pid = self()

    assert :ok =
             Lolek.ProcessingDeadline.run(
               fn ->
                 first_timeout = Lolek.ProcessingDeadline.limit_timeout(5_000)
                 Process.sleep(20)
                 second_timeout = Lolek.ProcessingDeadline.limit_timeout(5_000)
                 send(test_pid, {:timeouts, first_timeout, second_timeout})
                 :ok
               end,
               100
             )

    assert_receive {:timeouts, first_timeout, second_timeout}
    assert first_timeout <= 100
    assert second_timeout < first_timeout
  end

  @tag :tmp_dir
  test "terminates an in-flight OS process tree before returning a deadline error", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
    script_path = Path.join(tmp_dir, "ignore-term.sh")
    parent_pid_file = Path.join(tmp_dir, "parent-pid")
    child_pid_file = Path.join(tmp_dir, "child-pid")

    File.write!(script_path, """
    printf '%s' "$$" > "$1"
    trap '' TERM
    sh -c 'printf "%s" "$$" > "$1"; trap "" TERM; exec sleep 30' sh "$2" &
    wait
    """)

    assert {:error, :processing_deadline_exceeded} =
             Lolek.ProcessingDeadline.run(
               fn ->
                 Lolek.Command.run("sh", [script_path, parent_pid_file, child_pid_file],
                   timeout: :infinity,
                   kill_timeout: 1
                 )
               end,
               500
             )

    parent_os_pid = read_os_pid(parent_pid_file)
    child_os_pid = read_os_pid(child_pid_file)

    on_exit(fn ->
      for os_pid <- [child_os_pid, parent_os_pid], os_process_alive?(os_pid) do
        :exec.kill(os_pid, :sigkill)
      end
    end)

    refute_os_process_alive(parent_os_pid)
    refute_os_process_alive(child_os_pid)
  end

  @spec read_os_pid(Path.t()) :: pos_integer()
  defp read_os_pid(path), do: path |> File.read!() |> String.to_integer()

  @spec refute_os_process_alive(pos_integer(), non_neg_integer()) :: :ok
  defp refute_os_process_alive(os_pid, attempts \\ 100)

  defp refute_os_process_alive(os_pid, 0) do
    refute os_process_alive?(os_pid), "expected OS process #{os_pid} to have exited"
  end

  defp refute_os_process_alive(os_pid, attempts) do
    if os_process_alive?(os_pid) do
      Process.sleep(10)
      refute_os_process_alive(os_pid, attempts - 1)
    else
      :ok
    end
  end

  @spec os_process_alive?(pos_integer()) :: boolean()
  defp os_process_alive?(os_pid) do
    :ok == :exec.kill(os_pid, 0)
  end
end
