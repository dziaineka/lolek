defmodule Lolek.FileCleanerTest do
  use ExUnit.Case

  @cleaner_env_keys [
    :download_path,
    :max_download_dir_size
  ]

  setup do
    start_supervised!({Registry, keys: :unique, name: Lolek.UrlProcessingRegistry})
    :ok
  end

  @tag :tmp_dir
  test "uses configured download directory and max size", %{tmp_dir: tmp_dir} do
    preserve_cleaner_env(fn ->
      entry = create_cache_entry(tmp_dir, "cache-entry", [{"ready_to_telegram/file.mp4", 4}])

      Application.put_env(:lolek, :download_path, tmp_dir)
      Application.put_env(:lolek, :max_download_dir_size, 0)

      assert :ok = Lolek.FileCleaner.cleanup_downloads_directory()
      refute File.exists?(entry)
    end)
  end

  @tag :tmp_dir
  test "removes oldest media while preserving cache metadata", %{
    tmp_dir: tmp_dir
  } do
    old_entry =
      create_cache_entry(tmp_dir, "old", [
        {"ready_to_telegram/media_manifest.json", 2},
        {"source_metadata.json", 2},
        {"downloaded.mp4", 6}
      ])

    new_entry =
      create_cache_entry(tmp_dir, "new", [
        {"ready_to_telegram/media_manifest.json", 2},
        {"source_metadata.json", 2}
      ])

    touch!(old_entry, {{2024, 1, 1}, {0, 0, 0}})
    touch!(new_entry, {{2024, 1, 2}, {0, 0, 0}})

    assert :ok = Lolek.FileCleaner.cleanup_downloads_directory(tmp_dir, 8)

    assert File.exists?(old_entry)
    assert File.exists?(new_entry)
    refute File.exists?(Path.join(old_entry, "downloaded.mp4"))
    assert File.exists?(Path.join(old_entry, "ready_to_telegram/media_manifest.json"))
    assert File.exists?(Path.join(old_entry, "source_metadata.json"))
  end

  @tag :tmp_dir
  test "removes whole oldest entries when media cleanup is insufficient", %{tmp_dir: tmp_dir} do
    old_entry =
      create_cache_entry(tmp_dir, "old", [
        {"ready_to_telegram/media_manifest.json", 6},
        {"downloaded.mp4", 6}
      ])

    new_entry =
      create_cache_entry(tmp_dir, "new", [{"ready_to_telegram/media_manifest.json", 6}])

    touch!(old_entry, {{2024, 1, 1}, {0, 0, 0}})
    touch!(new_entry, {{2024, 1, 2}, {0, 0, 0}})

    assert :ok = Lolek.FileCleaner.cleanup_downloads_directory(tmp_dir, 6)

    refute File.exists?(old_entry)
    assert File.exists?(new_entry)
  end

  test "missing download directory is treated as empty" do
    assert :ok = Lolek.FileCleaner.cleanup_downloads_directory("/tmp/lolek-missing-downloads", 0)
  end

  @tag :tmp_dir
  test "does not remove cache entries that are being processed", %{tmp_dir: tmp_dir} do
    active_entry = create_cache_entry(tmp_dir, "active", [{"downloaded.mp4", 6}])
    inactive_entry = create_cache_entry(tmp_dir, "inactive", [{"downloaded.mp4", 6}])

    touch!(active_entry, {{2024, 1, 1}, {0, 0, 0}})
    touch!(inactive_entry, {{2024, 1, 2}, {0, 0, 0}})

    processing_pid = register_active_entry("active")

    assert :ok = Lolek.FileCleaner.cleanup_downloads_directory(tmp_dir, 0)
    assert File.exists?(active_entry)
    refute File.exists?(inactive_entry)

    send(processing_pid, :stop)
  end

  defp create_cache_entry(downloads_dir, name, files) do
    entry_dir = Path.join(downloads_dir, name)

    Enum.each(files, fn {relative_path, size} ->
      path = Path.join(entry_dir, relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, String.duplicate("x", size))
    end)

    entry_dir
  end

  defp touch!(path, time) do
    File.touch!(path, time)
  end

  defp register_active_entry(name) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _owner} = Registry.register(Lolek.UrlProcessingRegistry, name, nil)
        send(parent, :entry_registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :entry_registered
    pid
  end

  defp preserve_cleaner_env(fun) do
    app_env = Map.new(@cleaner_env_keys, &{&1, Application.fetch_env(:lolek, &1)})

    try do
      fun.()
    after
      Enum.each(app_env, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)
    end
  end
end
