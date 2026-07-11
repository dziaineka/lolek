defmodule Lolek.TiktokAudioMuxerTest do
  use ExUnit.Case

  @env_keys [:convert_command_timeout_seconds, :probe_command_timeout_seconds]

  @tag :tmp_dir
  test "tries TikTok audio URLs in bitrate and fallback order", %{tmp_dir: tmp_dir} do
    preserve_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      attempts_file = Path.join(tmp_dir, "attempts")
      gallery_dir = Path.join(tmp_dir, "gallery")
      info_dir = Path.join(gallery_dir, "tiktok/user")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.mkdir_p!(bin_dir)
      File.mkdir_p!(info_dir)
      File.write!(file_path, "video-only")

      File.write!(
        Path.join(info_dir, "info.json"),
        Jason.encode!(%{
          "category" => "tiktok",
          "video" => %{
            "bitrateAudioInfo" => [
              %{
                "Bitrate" => 32_000,
                "UrlList" => %{
                  "FallbackUrl" => "https://cdn.example.test/low-fallback.m4a",
                  "MainUrl" => "https://cdn.example.test/low-main.m4a",
                  "BackupUrl" => "not-a-url"
                }
              },
              %{
                "Bitrate" => 64_000,
                "UrlList" => %{
                  "FallbackUrl" => "https://cdn.example.test/high-fallback.m4a",
                  "MainUrl" => "https://cdn.example.test/high-main.m4a",
                  "BackupUrl" => "ftp://cdn.example.test/high-backup.m4a"
                }
              }
            ]
          },
          "music" => %{"playUrl" => "https://cdn.example.test/music.m4a"}
        })
      )

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
      [ "$audio_url" = "https://cdn.example.test/high-main.m4a" ] || exit 8
      printf muxed > "$output"
      """)

      set_env(bin_dir)

      assert :ok = Lolek.TiktokAudioMuxer.maybe_mux(gallery_dir, file_path)

      assert File.read!(file_path) == "muxed"

      assert File.read!(attempts_file) ==
               "https://cdn.example.test/high-fallback.m4a\n" <>
                 "https://cdn.example.test/high-main.m4a\n"
    end)
  end

  @tag :tmp_dir
  test "leaves files with existing audio unchanged", %{tmp_dir: tmp_dir} do
    preserve_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      gallery_dir = Path.join(tmp_dir, "gallery")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.mkdir_p!(bin_dir)
      File.mkdir_p!(gallery_dir)
      File.write!(file_path, "already-has-audio")

      write_script(bin_dir, "ffprobe", """
      #!/bin/sh
      printf 'video\\naudio\\n'
      """)

      write_script(bin_dir, "ffmpeg", "#!/bin/sh\nexit 9")

      set_env(bin_dir)

      assert :ok = Lolek.TiktokAudioMuxer.maybe_mux(gallery_dir, file_path)
      assert File.read!(file_path) == "already-has-audio"
    end)
  end

  defp preserve_env(fun) do
    app_env = Map.new(@env_keys, &{&1, Application.fetch_env(:lolek, &1)})
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

  defp set_env(bin_dir) do
    System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
    Application.put_env(:lolek, :convert_command_timeout_seconds, 5)
    Application.put_env(:lolek, :probe_command_timeout_seconds, 5)
  end

  defp write_script(bin_dir, name, content) do
    path = Path.join(bin_dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
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
