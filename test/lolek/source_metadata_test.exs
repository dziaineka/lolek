defmodule Lolek.SourceMetadataTest do
  use ExUnit.Case

  @metadata_env_keys [
    :download_command_timeout_seconds
  ]

  @tag :tmp_dir
  test "fetches sanitizes and caches yt-dlp captions", %{tmp_dir: tmp_dir} do
    preserve_metadata_env(fn ->
      calls_file = Path.join(tmp_dir, "calls")
      bin_dir = Path.join(tmp_dir, "bin")

      put_fake_yt_dlp(bin_dir, """
      printf x >> "#{calls_file}"
      printf '%s' '{"description":"Watch https://example.com/source now\\nnext line","title":"Fallback"}'
      """)

      put_metadata_env(bin_dir)

      assert {:ok, "Watch now\nnext line"} =
               Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)

      assert File.read!(calls_file) == "x"

      assert {:ok, %{"caption" => "Watch now\nnext line"}} =
               tmp_dir
               |> Path.join("source_metadata.json")
               |> File.read!()
               |> Jason.decode()
    end)
  end

  @tag :tmp_dir
  test "uses cached source caption without running yt-dlp", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "source_metadata.json"), Jason.encode!(%{caption: "Cached"}))

    assert {:ok, "Cached"} =
             Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)
  end

  @tag :tmp_dir
  test "sanitizes cached source captions while preserving newlines", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "source_metadata.json"),
      Jason.encode!(%{
        caption: "First line https://example.com/source\r\n  second\tline\n\n\nthird line  "
      })
    )

    assert {:ok, "First line\nsecond line\n\nthird line"} =
             Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)
  end

  @tag :tmp_dir
  test "caches nil when yt-dlp metadata has no text fields", %{tmp_dir: tmp_dir} do
    preserve_metadata_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")

      put_fake_yt_dlp(bin_dir, """
      printf '{}'
      """)

      put_metadata_env(bin_dir)

      assert {:ok, nil} =
               Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)

      assert {:ok, %{"caption" => nil}} =
               tmp_dir
               |> Path.join("source_metadata.json")
               |> File.read!()
               |> Jason.decode()
    end)
  end

  defp preserve_metadata_env(fun) do
    app_env = Map.new(@metadata_env_keys, &{&1, Application.fetch_env(:lolek, &1)})
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

  defp put_metadata_env(bin_dir) do
    Application.put_env(:lolek, :download_command_timeout_seconds, 5)

    System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
  end

  defp put_fake_yt_dlp(bin_dir, body) do
    file_path = Path.join(bin_dir, "yt-dlp")

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
