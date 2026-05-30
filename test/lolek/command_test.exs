defmodule Lolek.CommandTest do
  use ExUnit.Case

  @tag :tmp_dir
  test "captures stdout and stderr", %{tmp_dir: tmp_dir} do
    preserve_path(fn ->
      bin_dir = Path.join(tmp_dir, "bin")

      put_fake_executable(bin_dir, "talk", """
      printf out
      printf err >&2
      """)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, result} = Lolek.Command.run("talk", [])
      assert IO.iodata_to_binary(Keyword.fetch!(result, :stdout)) == "out"
      assert IO.iodata_to_binary(Keyword.fetch!(result, :stderr)) == "err"
    end)
  end

  @tag :tmp_dir
  test "returns exit status on command failure", %{tmp_dir: tmp_dir} do
    preserve_path(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      put_fake_executable(bin_dir, "fail", "exit 7")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, [exit_status: 7]} = Lolek.Command.run("fail", [])
    end)
  end

  @tag :tmp_dir
  test "stops commands that exceed their timeout", %{tmp_dir: tmp_dir} do
    preserve_path(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      finished_file = Path.join(tmp_dir, "finished")

      put_fake_executable(bin_dir, "slow", """
      sleep 5
      printf done > "#{finished_file}"
      """)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, {:command_timeout, "slow", 100}} =
               Lolek.Command.run("slow", [], timeout: 100, kill_timeout: 1)

      refute File.exists?(finished_file)
    end)
  end

  defp put_fake_executable(bin_dir, name, body) do
    file_path = Path.join(bin_dir, name)

    File.mkdir_p!(bin_dir)

    File.write!(file_path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(file_path, 0o755)
  end

  defp preserve_path(fun) do
    path = System.get_env("PATH")

    try do
      fun.()
    after
      restore_env("PATH", path)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp path_delimiter do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end
end
