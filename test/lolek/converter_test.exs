defmodule Lolek.ConverterTest do
  use ExUnit.Case

  @converter_env_keys [
    :max_file_size_to_send_to_telegram,
    :max_video_size_to_send_to_telegram,
    :max_audio_size_to_send_to_telegram,
    :max_file_size_to_compress,
    :max_duration_to_compress
  ]

  @tag :tmp_dir
  test "returns an error when downloaded mp4 is missing", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "downloaded.mp4")

    assert {:error, :enoent} = Lolek.Converter.adapt_to_telegram({:downloaded, file_path})
  end

  @tag :tmp_dir
  test "returns an error when video duration cannot be determined", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, "video")
      put_fake_executable(bin_dir, "ffprobe", "exit 1")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :video_duration} =
               Lolek.Converter.adapt_to_telegram({:downloaded, file_path})
    end)
  end

  @tag :tmp_dir
  test "returns an error when ffmpeg encode fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, _reason} = Lolek.Converter.adapt_to_telegram({:downloaded, file_path})
    end)
  end

  @tag :tmp_dir
  test "returns an error when ffmpeg succeeds without output", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 0")
      put_compression_env()

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :enoent} = Lolek.Converter.adapt_to_telegram({:downloaded, file_path})
    end)
  end

  @tag :tmp_dir
  test "returns an error when original file cannot be renamed", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "downloaded.txt")

    assert {:error, {:rename_compressed_failed, :enoent}} =
             Lolek.Converter.adapt_to_telegram({:downloaded, file_path})
  end

  defp preserve_converter_env(fun) do
    app_env = Map.new(@converter_env_keys, &{&1, Application.fetch_env(:lolek, &1)})
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

  defp put_compression_env do
    Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1)
    Application.put_env(:lolek, :max_video_size_to_send_to_telegram, 800)
    Application.put_env(:lolek, :max_audio_size_to_send_to_telegram, 200)
    Application.put_env(:lolek, :max_file_size_to_compress, 100)
    Application.put_env(:lolek, :max_duration_to_compress, 100)
  end

  defp put_video_probe(bin_dir, duration, codec) do
    put_fake_executable(bin_dir, "ffprobe", """
    case "$*" in
      *stream=duration*)
        printf '#{duration}\\n'
        ;;
      *stream=codec_name*)
        printf '#{codec}\\n'
        ;;
      *)
        exit 1
        ;;
    esac
    """)
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp path_delimiter do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end
end
