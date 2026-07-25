defmodule Lolek.FileTest do
  use ExUnit.Case

  @file_env_keys [
    :max_file_size_to_send_to_telegram,
    :probe_command_timeout_seconds
  ]

  @tag :tmp_dir
  test "reads existing single-file caches as one-item ready media", %{tmp_dir: tmp_dir} do
    ready_path = Path.join([tmp_dir, "ready_to_telegram", "telegram-file-id.txt"])

    File.mkdir_p!(Path.dirname(ready_path))
    File.write!(ready_path, "document")

    assert {:ok, {:ready_media, [{"telegram-file-id", ".txt"}]}} =
             Lolek.File.get_file_state(tmp_dir)
  end

  @tag :tmp_dir
  test "caches one or more sent media entries in a shared manifest", %{tmp_dir: tmp_dir} do
    entries = [{".jpg", "photo-id"}, {".mp4", "video-id"}]
    manifest_path = Path.join([tmp_dir, "ready_to_telegram", "media_manifest.json"])

    assert :ok =
             Lolek.File.move_to_ready_to_telegram(
               {:sent_media, tmp_dir, [{".jpg", "single-photo-id"}]}
             )

    assert Jason.decode!(File.read!(manifest_path)) == [
             %{"ext" => ".jpg", "file_id" => "single-photo-id"}
           ]

    assert :ok = Lolek.File.move_to_ready_to_telegram({:sent_media, tmp_dir, entries})

    assert Jason.decode!(File.read!(manifest_path)) == [
             %{"ext" => ".jpg", "file_id" => "photo-id"},
             %{"ext" => ".mp4", "file_id" => "video-id"}
           ]

    assert {:ok, {:ready_media, [{"photo-id", ".jpg"}, {"video-id", ".mp4"}]}} =
             Lolek.File.get_file_state(tmp_dir)
  end

  @tag :tmp_dir
  test "reads existing gallery manifests as ready media", %{tmp_dir: tmp_dir} do
    ready_path = Path.join(tmp_dir, "ready_to_telegram")
    manifest_path = Path.join(ready_path, "gallery_manifest.json")

    File.mkdir_p!(ready_path)
    File.write!(manifest_path, Jason.encode!([%{"file_id" => "photo-id", "ext" => ".jpg"}]))

    assert {:ok, {:ready_media, [{"photo-id", ".jpg"}]}} =
             Lolek.File.get_file_state(tmp_dir)
  end

  test "ignores file states that do not need caching" do
    assert :ok = Lolek.File.move_to_ready_to_telegram({:ready_media, [{"file-id", ".mp4"}]})
  end

  @tag :tmp_dir
  test "uses container duration when the video stream duration is unavailable", %{
    tmp_dir: tmp_dir
  } do
    preserve_file_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "video.mkv")

      put_fake_executable(bin_dir, "ffprobe", """
      printf '{"streams":[{"codec_type":"video"},{"codec_type":"audio","duration":"61.2"}],"format":{"duration":"60.101000"}}\n'
      """)

      put_cache_env(bin_dir)

      assert {:ok, 60} = Lolek.File.get_video_duration(file_path)
    end)
  end

  @tag :tmp_dir
  test "uses audio duration when video and container durations are unavailable", %{
    tmp_dir: tmp_dir
  } do
    preserve_file_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "video.mkv")

      put_fake_executable(bin_dir, "ffprobe", """
      printf '{"streams":[{"codec_type":"video"},{"codec_type":"audio","duration":"60.101000"}],"format":{}}\n'
      """)

      put_cache_env(bin_dir)

      assert {:ok, 60} = Lolek.File.get_video_duration(file_path)
    end)
  end

  @tag :tmp_dir
  test "ignores invalid compressed cache files", %{tmp_dir: tmp_dir} do
    preserve_file_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      compressed_path = Path.join(tmp_dir, "compressed.mp4")
      downloaded_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(compressed_path, "broken")
      File.write!(downloaded_path, "video")
      put_fake_executable(bin_dir, "ffprobe", "exit 0")
      put_cache_env(bin_dir)

      assert {:ok, {:downloaded_media, ^tmp_dir, [^downloaded_path]}} =
               Lolek.File.get_file_state(tmp_dir)

      refute File.exists?(compressed_path)
    end)
  end

  @tag :tmp_dir
  test "ignores invalid ready-to-telegram cache files", %{tmp_dir: tmp_dir} do
    preserve_file_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      ready_dir = Path.join(tmp_dir, "ready_to_telegram")
      ready_path = Path.join(ready_dir, "telegram-file-id.mp4")
      downloaded_path = Path.join(tmp_dir, "downloaded.mp4")

      File.mkdir_p!(ready_dir)
      File.write!(ready_path, "broken")
      File.write!(downloaded_path, "video")
      put_fake_executable(bin_dir, "ffprobe", "exit 0")
      put_cache_env(bin_dir)

      assert {:ok, {:downloaded_media, ^tmp_dir, [^downloaded_path]}} =
               Lolek.File.get_file_state(tmp_dir)

      refute File.exists?(ready_path)
    end)
  end

  defp preserve_file_env(fun) do
    app_env = Map.new(@file_env_keys, &{&1, Application.fetch_env(:lolek, &1)})
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

  defp put_cache_env(bin_dir) do
    Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)
    Application.put_env(:lolek, :probe_command_timeout_seconds, 5)

    System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
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
