defmodule Lolek.DownloaderTest do
  use ExUnit.Case

  @download_env_keys [
    :max_download_tries,
    :start_download_pause,
    :max_download_pause,
    :download_command_timeout_seconds,
    :convert_command_timeout_seconds,
    :probe_command_timeout_seconds,
    :max_file_size_to_compress,
    :gallery_download_enabled,
    :max_file_size_to_send_to_telegram
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
      max_filesize=
      no_playlist=0
      remux_video=

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --recode-video)
            exit 11
            ;;
          --remux-video)
            shift
            remux_video="$1"
            ;;
          --max-filesize)
            shift
            max_filesize="$1"
            ;;
          -o)
            shift
            output="$1"
            ;;
          --no-playlist)
            no_playlist=1
            ;;
        esac

        shift
      done

      [ "$max_filesize" = "12345" ] || exit 9
      [ "$no_playlist" = "1" ] || exit 10
      [ "$remux_video" = "mp4" ] || exit 12
      printf video > "$output"
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 1)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)
      Application.put_env(:lolek, :download_command_timeout_seconds, 5)
      Application.put_env(:lolek, :max_file_size_to_compress, 12_345)

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
      probes_file = Path.join(tmp_dir, "probes")
      bin_dir = Path.join(tmp_dir, "bin")
      fake_yt_dlp = Path.join(bin_dir, "yt-dlp")

      File.mkdir_p!(bin_dir)

      File.write!(fake_yt_dlp, """
      #!/bin/sh
      for arg in "$@"; do
        if [ "$arg" = "--simulate" ]; then
          printf x >> "#{probes_file}"
          printf '[{"format_id":"1"}]\\n'
          exit 0
        fi
      done

      printf x >> "#{attempts_file}"
      exit 1
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 3)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)
      Application.put_env(:lolek, :download_command_timeout_seconds, 5)
      Application.put_env(:lolek, :max_file_size_to_compress, 12_345)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, "Error when downloading url: https://example.com/video; reason: " <> reason} =
               Lolek.Downloader.download(
                 "https://example.com/video?token=secret#fragment",
                 {:new_file, tmp_dir}
               )

      refute reason =~ "token=secret"
      refute reason =~ "fragment"

      assert File.read!(attempts_file) == "xxx"
      assert File.read!(probes_file) == "x"
    end)
  end

  @tag :tmp_dir
  test "does not retry yt-dlp urls without video formats", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      attempts_file = Path.join(tmp_dir, "attempts")
      probes_file = Path.join(tmp_dir, "probes")
      bin_dir = Path.join(tmp_dir, "bin")
      fake_yt_dlp = Path.join(bin_dir, "yt-dlp")

      File.mkdir_p!(bin_dir)

      File.write!(fake_yt_dlp, """
      #!/bin/sh
      for arg in "$@"; do
        if [ "$arg" = "--simulate" ]; then
          printf x >> "#{probes_file}"
          printf '[]\\n'
          exit 0
        fi
      done

      printf x >> "#{attempts_file}"
      printf 'download failed\\n' >&2
      exit 1
      """)

      File.chmod!(fake_yt_dlp, 0o755)

      Application.put_env(:lolek, :max_download_tries, 3)
      Application.put_env(:lolek, :start_download_pause, 0)
      Application.put_env(:lolek, :max_download_pause, 0)
      Application.put_env(:lolek, :download_command_timeout_seconds, 5)
      Application.put_env(:lolek, :max_file_size_to_compress, 12_345)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_video_formats} =
               Lolek.Downloader.download("https://example.com/video", {:new_file, tmp_dir})

      assert File.read!(attempts_file) == "x"
      assert File.read!(probes_file) == "x"
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
      Application.put_env(:lolek, :download_command_timeout_seconds, 5)
      Application.put_env(:lolek, :max_file_size_to_compress, 12_345)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, "File not found"} =
               Lolek.Downloader.download("https://example.com/video", {:new_file, tmp_dir})
    end)
  end

  @tag :tmp_dir
  test "routes gallery-dl image results to downloaded_gallery state", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", """
      #!/bin/sh
      dest=
      while [ "$#" -gt 0 ]; do
        case "$1" in --dest) shift; dest="$1" ;; esac
        shift
      done
      printf photo > "$dest/photo001.jpg"
      printf photo > "$dest/photo002.jpg"
      """)

      write_script(bin_dir, "yt-dlp", "#!/bin/sh\nexit 1")

      set_gallery_env(bin_dir, true)

      assert {:ok, {:downloaded_gallery, gallery_dir, files}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})

      assert gallery_dir == Path.join(tmp_dir, "gallery")
      assert length(files) == 2
      assert Enum.all?(files, &String.ends_with?(&1, ".jpg"))
    end)
  end

  @tag :tmp_dir
  test "promotes single mp4 from gallery-dl to downloaded state", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", """
      #!/bin/sh
      dest=
      while [ "$#" -gt 0 ]; do
        case "$1" in --dest) shift; dest="$1" ;; esac
        shift
      done
      printf videodata > "$dest/video001.mp4"
      """)

      write_script(bin_dir, "yt-dlp", "#!/bin/sh\nexit 1")

      set_gallery_env(bin_dir, true)

      assert {:ok, {:downloaded, file_path}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})

      assert Path.basename(file_path) == "downloaded.mp4"
      assert Path.dirname(file_path) == tmp_dir
      assert File.read!(file_path) == "videodata"
    end)
  end

  @tag :tmp_dir
  test "muxes TikTok gallery video-only mp4 before returning downloaded state", %{
    tmp_dir: tmp_dir
  } do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      attempts_file = Path.join(tmp_dir, "ffmpeg-attempts")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", """
      #!/bin/sh
      dest=
      while [ "$#" -gt 0 ]; do
        case "$1" in --dest) shift; dest="$1" ;; esac
        shift
      done
      mkdir -p "$dest/tiktok/user"
      printf video > "$dest/tiktok/user/video001.mp4"
      cat > "$dest/tiktok/user/info.json" <<'JSON'
      {
        "category": "tiktok",
        "video": {
          "bitrateAudioInfo": [
            {
              "Bitrate": 64000,
              "UrlList": {
                "FallbackUrl": "https://cdn.example.test/bad-audio.m4a",
                "MainUrl": "https://cdn.example.test/good-audio.m4a",
                "BackupUrl": "not-a-url"
              }
            }
          ]
        }
      }
      JSON
      """)

      write_script(bin_dir, "ffprobe", """
      #!/bin/sh
      last=
      for arg in "$@"; do last="$arg"; done
      case "$last" in
        *downloaded-with-audio.mp4) printf 'video\\naudio\\n' ;;
        *) printf 'video\\n' ;;
      esac
      """)

      write_script(bin_dir, "ffmpeg", """
      #!/bin/sh
      input_count=0
      audio_url=
      output=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -i)
            shift
            input_count=$((input_count + 1))
            if [ "$input_count" = 2 ]; then audio_url="$1"; fi
            ;;
          *)
            output="$1"
            ;;
        esac
        shift
      done
      printf '%s\\n' "$audio_url" >> "#{attempts_file}"
      [ "$audio_url" = "https://cdn.example.test/good-audio.m4a" ] || exit 7
      printf muxed > "$output"
      """)

      write_script(bin_dir, "yt-dlp", "#!/bin/sh\nexit 1")

      set_gallery_env(bin_dir, true)

      assert {:ok, {:downloaded, file_path}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})

      assert Path.basename(file_path) == "downloaded.mp4"
      assert File.read!(file_path) == "muxed"

      assert File.read!(attempts_file) ==
               "https://cdn.example.test/bad-audio.m4a\n" <>
                 "https://cdn.example.test/good-audio.m4a\n"
    end)
  end

  @tag :tmp_dir
  test "falls back to yt-dlp when gallery-dl returns no files", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", """
      #!/bin/sh
      dest=
      while [ "$#" -gt 0 ]; do
        case "$1" in --dest) shift; dest="$1" ;; esac
        shift
      done
      printf meta > "$dest/post.json"
      """)

      write_script(bin_dir, "yt-dlp", """
      #!/bin/sh
      for arg in "$@"; do
        if [ "$prev" = "-o" ]; then printf video > "$arg"; fi
        prev="$arg"
      done
      """)

      set_gallery_env(bin_dir, true)

      assert {:ok, {:downloaded, file_path}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})

      assert Path.basename(file_path) == "downloaded.mp4"
    end)
  end

  @tag :tmp_dir
  test "falls back to yt-dlp when gallery-dl fails", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", "#!/bin/sh\nexit 1")

      write_script(bin_dir, "yt-dlp", """
      #!/bin/sh
      for arg in "$@"; do
        if [ "$prev" = "-o" ]; then printf video > "$arg"; fi
        prev="$arg"
      done
      """)

      set_gallery_env(bin_dir, true)

      assert {:ok, {:downloaded, file_path}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})

      assert Path.basename(file_path) == "downloaded.mp4"
    end)
  end

  @tag :tmp_dir
  test "skips gallery-dl when gallery download is disabled", %{tmp_dir: tmp_dir} do
    preserve_download_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      write_script(bin_dir, "gallery-dl", """
      #!/bin/sh
      echo "should not be called" >&2
      exit 99
      """)

      write_script(bin_dir, "yt-dlp", """
      #!/bin/sh
      for arg in "$@"; do
        if [ "$prev" = "-o" ]; then printf video > "$arg"; fi
        prev="$arg"
      done
      """)

      set_gallery_env(bin_dir, false)

      assert {:ok, {:downloaded, _file_path}} =
               Lolek.Downloader.download("https://example.com/post", {:new_file, tmp_dir})
    end)
  end

  defp set_gallery_env(bin_dir, gallery_enabled) do
    Application.put_env(:lolek, :gallery_download_enabled, gallery_enabled)
    Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100_000)
    Application.put_env(:lolek, :max_download_tries, 1)
    Application.put_env(:lolek, :start_download_pause, 0)
    Application.put_env(:lolek, :max_download_pause, 0)
    Application.put_env(:lolek, :download_command_timeout_seconds, 5)
    Application.put_env(:lolek, :convert_command_timeout_seconds, 5)
    Application.put_env(:lolek, :probe_command_timeout_seconds, 5)
    Application.put_env(:lolek, :max_file_size_to_compress, 12_345)
    System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
  end

  defp write_script(bin_dir, name, content) do
    path = Path.join(bin_dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
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
