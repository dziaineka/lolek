defmodule Lolek.SourceMetadataTest do
  use ExUnit.Case

  @metadata_env_keys [
    :download_command_timeout_seconds,
    :gallery_download_enabled
  ]

  @tag :tmp_dir
  test "fetches cleans and caches yt-dlp metadata as a post", %{tmp_dir: tmp_dir} do
    preserve_metadata_env(fn ->
      calls_file = Path.join(tmp_dir, "calls")
      bin_dir = Path.join(tmp_dir, "bin")

      put_fake_yt_dlp(bin_dir, """
      printf x >> "#{calls_file}"
      printf '%s' '{"description":"&gt; Watch https://example.com/source now\\nnext &amp; line &#62;","title":"A &quot;/ Video: Title?&quot;","uploader":"Uploader","uploader_id":"handle","like_count":5}'
      """)

      put_metadata_env(bin_dir)

      assert {:ok, %Lolek.Post{} = post} =
               Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)

      assert post.text == "> Watch https://example.com/source now\nnext & line >"
      assert post.title == "A Video Title"
      assert post.url == "https://example.com/video"
      assert post.author == %{name: "Uploader", handle: "handle", url: nil, verified: false}
      assert post.stats == %{likes: 5}
      assert post.source == :yt_dlp

      assert File.read!(calls_file) == "x"

      assert {:ok, ^post} =
               Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)

      assert File.read!(calls_file) == "x"
    end)
  end

  @tag :tmp_dir
  test "returns an error for an invalid cache entry", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "post.json"), Jason.encode!(%{text: 5}))

    assert {:error, "Cached source metadata is invalid"} =
             Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)
  end

  @tag :tmp_dir
  test "caches a post without text when yt-dlp metadata has no text fields", %{
    tmp_dir: tmp_dir
  } do
    preserve_metadata_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      put_fake_yt_dlp(bin_dir, "printf '{}'")
      put_metadata_env(bin_dir)

      assert {:ok, %Lolek.Post{text: nil, title: nil}} =
               Lolek.SourceMetadata.get_or_fetch("https://example.com/video", tmp_dir)

      assert {:ok, %{"text" => nil, "title" => nil}} =
               tmp_dir |> Path.join("post.json") |> File.read!() |> Jason.decode()
    end)
  end

  @tag :tmp_dir
  test "merges gallery-dl metadata into the post and caches it", %{tmp_dir: tmp_dir} do
    preserve_metadata_env(fn ->
      Application.put_env(:lolek, :gallery_download_enabled, false)
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(Path.join(gallery_dir, "twitter"))

      [[2, metadata] | _] =
        "test/fixtures/posts/x_gallery.gallery_dl.json" |> File.read!() |> Jason.decode!()

      File.write!(Path.join([gallery_dir, "twitter", "info.json"]), Jason.encode!(metadata))

      post = %Lolek.Post{source: :yt_dlp, url: "https://x.com/NASA/status/1", title: "Old title"}
      merged = Lolek.SourceMetadata.merge_gallery_metadata(post, tmp_dir, gallery_dir)

      assert merged.source == :gallery_dl
      assert merged.author.handle == "NASA"
      assert merged.stats.views == 223_819
      assert merged.title == "Old title"
      assert String.starts_with?(merged.text, "Good morning from MAX POWER @NASAKennedy!")

      assert {:ok, ^merged} =
               Lolek.SourceMetadata.get_or_fetch("https://x.com/NASA/status/1", tmp_dir)
    end)
  end

  @tag :tmp_dir
  test "keeps the post when the gallery has no metadata", %{tmp_dir: tmp_dir} do
    post = %Lolek.Post{text: "kept"}
    assert ^post = Lolek.SourceMetadata.merge_gallery_metadata(post, tmp_dir, tmp_dir)
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
