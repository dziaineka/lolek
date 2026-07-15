defmodule Lolek.GalleryDownloaderTest do
  use ExUnit.Case

  @env_keys [
    :max_file_size_to_send_to_telegram,
    :max_gallery_media,
    :download_command_timeout_seconds
  ]

  describe "download/2" do
    @tag :tmp_dir
    test "passes ytdl enabled and module options to gallery-dl", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        gallery_dir = Path.join(tmp_dir, "gallery")

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        dest=; media_range=; ytdl_enabled=0; ytdl_module=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --dest) shift; dest="$1" ;;
            --range) shift; media_range="$1" ;;
            -o)
              shift
              case "$1" in
                extractor.ytdl.enabled=true) ytdl_enabled=1 ;;
                extractor.ytdl.module=yt_dlp) ytdl_module=1 ;;
              esac
              ;;
          esac
          shift
        done
        [ "$ytdl_enabled" = "1" ] || exit 1
        [ "$ytdl_module" = "1" ] || exit 2
        [ "$media_range" = "1-50" ] || exit 3
        printf photo > "$dest/photo.jpg"
        """)

        set_env(bin_dir)

        assert {:ok, [path]} =
                 Lolek.GalleryDownloader.download("https://example.com/post", gallery_dir)

        assert Path.extname(path) == ".jpg"
      end)
    end

    @tag :tmp_dir
    test "returns both image and video files from the download dir", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        gallery_dir = Path.join(tmp_dir, "gallery")

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        dest=
        while [ "$#" -gt 0 ]; do
          case "$1" in --dest) shift; dest="$1" ;; esac
          shift
        done
        printf photo > "$dest/photo.jpg"
        printf video > "$dest/video.mp4"
        """)

        set_env(bin_dir)

        assert {:ok, files} =
                 Lolek.GalleryDownloader.download("https://example.com/post", gallery_dir)

        assert Enum.sort(Enum.map(files, &Path.extname/1)) == [".jpg", ".mp4"]
      end)
    end

    @tag :tmp_dir
    test "returns empty list when gallery-dl finds no supported files", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        gallery_dir = Path.join(tmp_dir, "gallery")

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        dest=
        while [ "$#" -gt 0 ]; do
          case "$1" in --dest) shift; dest="$1" ;; esac
          shift
        done
        printf meta > "$dest/post.json"
        """)

        set_env(bin_dir)

        assert {:ok, []} =
                 Lolek.GalleryDownloader.download("https://example.com/post", gallery_dir)
      end)
    end

    @tag :tmp_dir
    test "returns error when gallery-dl exits non-zero", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        gallery_dir = Path.join(tmp_dir, "gallery")

        write_script(bin_dir, "gallery-dl", "#!/bin/sh\nexit 1")
        set_env(bin_dir)

        assert {:error, {:gallery_dl, _reason}} =
                 Lolek.GalleryDownloader.download("https://example.com/post", gallery_dir)
      end)
    end
  end

  describe "list_media_files/1" do
    @tag :tmp_dir
    test "returns both image and video files", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)

        for name <- ~w(a.jpg b.png c.gif d.webp e.avif) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        for name <- ~w(v.mp4 v.mkv v.webm v.mov v.m4v) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        files = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert length(files) == 10

        assert Enum.all?(files, fn p ->
                 Path.extname(p) in ~w(.jpg .png .gif .webp .avif .mp4 .mkv .webm .mov .m4v)
               end)
      end)
    end

    @tag :tmp_dir
    test "filters files over the size limit", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 4)
        File.write!(Path.join(tmp_dir, "small.jpg"), "ok")
        File.write!(Path.join(tmp_dir, "large.jpg"), "toolarge!")

        assert [path] = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert Path.basename(path) == "small.jpg"
      end)
    end

    @tag :tmp_dir
    test "returns files sorted alphabetically", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)

        for name <- ~w(c.jpg a.jpg b.jpg) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        files = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert Enum.map(files, &Path.basename/1) == ["a.jpg", "b.jpg", "c.jpg"]
      end)
    end

    @tag :tmp_dir
    test "limits the total number of gallery media files", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)
        Application.put_env(:lolek, :max_gallery_media, 2)

        for name <- ~w(c.jpg a.jpg b.jpg) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        files = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert Enum.map(files, &Path.basename/1) == ["a.jpg", "b.jpg"]
      end)
    end

    @tag :tmp_dir
    test "returns empty list for empty or nonexistent directory", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)
        assert [] = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert [] = Lolek.GalleryDownloader.list_media_files(Path.join(tmp_dir, "missing"))
      end)
    end
  end

  describe "video_file?/1" do
    test "returns true for all supported video extensions" do
      for ext <- ~w(.mp4 .mkv .webm .mov .m4v) do
        assert Lolek.GalleryDownloader.video_file?("video#{ext}"),
               "expected true for #{ext}"
      end
    end

    test "is case-insensitive" do
      assert Lolek.GalleryDownloader.video_file?("VIDEO.MP4")
      assert Lolek.GalleryDownloader.video_file?("Clip.MKV")
    end

    test "returns false for image extensions" do
      for ext <- ~w(.jpg .jpeg .png .gif .webp .avif) do
        refute Lolek.GalleryDownloader.video_file?("photo#{ext}"),
               "expected false for #{ext}"
      end
    end
  end

  describe "read_caption/1" do
    @tag :tmp_dir
    test "reads caption from content field", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "post.json"), Jason.encode!(%{"content" => "Hello world"}))
      assert {:ok, "Hello world"} = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end

    @tag :tmp_dir
    test "falls back to description field when content is absent", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "post.json"),
        Jason.encode!(%{"description" => "A description"})
      )

      assert {:ok, "A description"} = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end

    @tag :tmp_dir
    test "falls back to title field when content and description are absent", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "post.json"), Jason.encode!(%{"title" => "Post title"}))
      assert {:ok, "Post title"} = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end

    @tag :tmp_dir
    test "reads caption from JSON in a subdirectory", %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "instagram/user")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "post.json"), Jason.encode!(%{"content" => "Nested caption"}))
      assert {:ok, "Nested caption"} = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end

    @tag :tmp_dir
    test "returns error when no JSON file is present", %{tmp_dir: tmp_dir} do
      assert :error = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end

    @tag :tmp_dir
    test "returns error when JSON has no recognized text field", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "post.json"), Jason.encode!(%{"id" => 123}))
      assert :error = Lolek.GalleryDownloader.read_caption(tmp_dir)
    end
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

  defp mkdir_bin(tmp_dir) do
    bin_dir = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin_dir)
    bin_dir
  end

  defp write_script(bin_dir, name, content) do
    path = Path.join(bin_dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp set_env(bin_dir) do
    System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
    {:ok, _} = Application.ensure_all_started(:erlexec)
    Application.put_env(:lolek, :download_command_timeout_seconds, 5)
    Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)
    Application.put_env(:lolek, :max_gallery_media, 50)
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
