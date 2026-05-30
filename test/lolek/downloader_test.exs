defmodule Lolek.DownloaderTest do
  use ExUnit.Case

  @download_env_keys [
    :max_download_tries,
    :start_download_pause,
    :max_download_pause
  ]

  test "uses dedicated threads downloader for threads urls" do
    assert Lolek.ThreadsDownloader =
             Lolek.Downloader.downloader_module(
               "https://www.threads.com/@helga_bri/post/DXum65XjCcD"
             )
  end

  test "uses yt-dlp for other urls" do
    assert :yt_dlp = Lolek.Downloader.downloader_module("https://x.com/example/status/1")
  end

  @tag :tmp_dir
  test "stores yt-dlp downloads with mp4 extension", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      fake_yt_dlp = Path.join(bin_dir, "yt-dlp")

      File.mkdir_p!(bin_dir)

      File.write!(fake_yt_dlp, """
      #!/bin/sh
      output=

      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
          shift
          output="$1"
        fi

        shift
      done

      printf video > "$output"
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 1)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:downloaded, file_path}} =
               Lolek.Downloader.download("https://example.com/video", {:new_file, tmp_dir})

      assert Path.basename(file_path) == "downloaded.mp4"
      assert File.read!(file_path) == "video"
    end)
  end

  @tag :tmp_dir
  test "uses max download tries as total attempts", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      attempts_file = Path.join(tmp_dir, "attempts")
      bin_dir = Path.join(tmp_dir, "bin")
      fake_yt_dlp = Path.join(bin_dir, "yt-dlp")

      File.mkdir_p!(bin_dir)

      File.write!(fake_yt_dlp, """
      #!/bin/sh
      printf x >> "#{attempts_file}"
      exit 1
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 3)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, "Error when downloading url: https://example.com/video; reason: " <> _} =
               Lolek.Downloader.download("https://example.com/video", {:new_file, tmp_dir})

      assert File.read!(attempts_file) == "xxx"
    end)
  end

  @tag :tmp_dir
  test "returns an error when downloader succeeds without creating a file", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      fake_yt_dlp = Path.join(bin_dir, "yt-dlp")

      File.mkdir_p!(bin_dir)

      File.write!(fake_yt_dlp, """
      #!/bin/sh
      exit 0
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 1)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, "File not found"} =
               Lolek.Downloader.download("https://example.com/video", {:new_file, tmp_dir})
    end)
  end

  defp preserve_download_env(fun) do
    app_env = Map.new(@download_env_keys, &{&1, Application.fetch_env(:lolek, &1)})
    path = System.get_env("PATH")

    try do
      fun.()
    after
      Enum.each(app_env, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)

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
