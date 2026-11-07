defmodule Lolek.GalleryDownloaderTest do
  use ExUnit.Case

  @env_keys [
    :max_file_size_to_send_to_telegram,
    :max_gallery_media,
    :download_command_timeout_seconds,
    :gallery_dl_cookies_file,
    :gallery_download_enabled
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

  describe "cookies fallback" do
    # The fake gallery-dl fails like Twitter/X does for logged-in sessions.
    @fake_gallery_dl """
    #!/bin/sh
    dest=; dump=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cookies) echo "[twitter][error] HttpError: 404" >&2; exit 4 ;;
        --dest) shift; dest="$1" ;;
        --dump-json) dump=1 ;;
      esac
      shift
    done
    if [ "$dump" = "1" ]; then
      printf '[[2, {"content": "guest text"}]]'
    else
      printf photo > "$dest/photo.jpg"
    fi
    """

    @tag :tmp_dir
    test "downloads media again without cookies when gallery-dl fails with them", %{
      tmp_dir: tmp_dir
    } do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        write_script(bin_dir, "gallery-dl", @fake_gallery_dl)
        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, Path.join(tmp_dir, "cookies.txt"))

        assert {:ok, [path]} =
                 Lolek.GalleryDownloader.download(
                   "https://x.com/user/status/1",
                   Path.join(tmp_dir, "gallery")
                 )

        assert Path.basename(path) == "photo.jpg"
      end)
    end

    @tag :tmp_dir
    test "reads text posts again without cookies when gallery-dl fails with them", %{
      tmp_dir: tmp_dir
    } do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)
        write_script(bin_dir, "gallery-dl", @fake_gallery_dl)
        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, Path.join(tmp_dir, "cookies.txt"))

        assert {:ok, "guest text"} =
                 Lolek.GalleryDownloader.fetch_text_post("https://x.com/user/status/1")
      end)
    end
  end

  describe "post metadata" do
    @tag :tmp_dir
    test "writes the metadata of text posts to the info file", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        printf '%s' '[[2, {"category": "twitter", "content": "post text", "tweet_id": 20}]]'
        """)

        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, nil)
        info_json_path = Path.join([tmp_dir, "gallery", "info.json"])

        assert {:ok, "post text"} =
                 Lolek.GalleryDownloader.fetch_text_post(
                   "https://x.com/user/status/20",
                   info_json_path
                 )

        assert %{"category" => "twitter", "content" => "post text"} =
                 info_json_path |> File.read!() |> Jason.decode!()
      end)
    end

    @tag :tmp_dir
    test "reads metadata again without cookies when gallery-dl reports an error with them", %{
      tmp_dir: tmp_dir
    } do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)

        # Logged-in X requests can fail in the client transaction step. gallery-dl then
        # prints an error message and exits with status 0.
        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        case "$*" in
          *--cookies*) printf '%s' '[[-1, {"error": "AbortExtraction", "message": "key"}]]' ;;
          *) printf '%s' '[[2, {"category": "twitter", "content": "guest", "tweet_id": 1}]]' ;;
        esac
        """)

        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, Path.join(tmp_dir, "cookies.txt"))

        assert {:ok, [[2, %{"content" => "guest"}]]} =
                 Lolek.GalleryDownloader.fetch_metadata("https://x.com/i/status/1")
      end)
    end

    @tag :tmp_dir
    test "returns gallery-dl error messages", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        printf '%s' '[[-1, {"error": "NotFoundError"}]]'
        """)

        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, nil)

        assert {:error, {:gallery_dl_error, %{"error" => "NotFoundError"}}} =
                 Lolek.GalleryDownloader.fetch_metadata("https://x.com/i/status/1")
      end)
    end

    @tag :tmp_dir
    test "fetches the quoted tweet and the parent tweet", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        bin_dir = mkdir_bin(tmp_dir)

        write_script(bin_dir, "gallery-dl", """
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{tmp_dir}/calls"
        for arg; do last=$arg; done
        case "$last" in
          */20) printf '%s' '[[2, {"category": "twitter", "content": "main", "tweet_id": 20, "quote_id": 0}], [2, {"category": "twitter", "content": "quoted", "tweet_id": 30, "quote_id": 20, "author": {"name": "q", "nick": "Q"}}], [3, "https://pbs.twimg.com/media/a.jpg", {"category": "twitter", "tweet_id": 30, "quote_id": 20, "extension": "jpg"}]]' ;;
          */10) printf '%s' '[[2, {"category": "twitter", "content": "parent", "tweet_id": 10, "author": {"name": "p"}}]]' ;;
          *) exit 1 ;;
        esac
        """)

        set_env(bin_dir)
        Application.put_env(:lolek, :gallery_dl_cookies_file, nil)
        Application.put_env(:lolek, :gallery_download_enabled, true)

        post =
          Lolek.Post.GalleryDl.parse(%{
            "category" => "twitter",
            "content" => "@p main",
            "tweet_id" => 20,
            "reply_id" => 10,
            "reply_to" => "p",
            "author" => %{"name" => "me"}
          })

        enriched = Lolek.Post.Enricher.enrich(post)

        assert %Lolek.Post{text: "quoted", author: %{name: "Q", handle: "q"}} = enriched.quoted
        assert [%{type: :photo, url: "https://pbs.twimg.com/media/a.jpg"}] = enriched.quoted.media
        assert %Lolek.Post{text: "parent", author: %{handle: "p"}} = enriched.reply_to
        assert enriched.text == "main"
        assert enriched.extra.linked_posts == "fetched"

        assert File.read!(Path.join(tmp_dir, "calls")) =~
                 "-o extractor.twitter.quoted=true"

        # The linked posts are fetched one time.
        assert Lolek.Post.Enricher.enrich(enriched) == enriched

        # A failed fetch does not mark the post, so the next request tries again.
        failed = Lolek.Post.Enricher.enrich(%{post | url: "https://x.com/me/status/99"})
        assert failed.quoted == nil
        refute Map.has_key?(failed.extra, :linked_posts)

        Application.put_env(:lolek, :gallery_download_enabled, false)
        assert Lolek.Post.Enricher.enrich(post) == post
      end)
    end
  end

  describe "list_media_files/1" do
    @tag :tmp_dir
    test "returns both image and video files", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1000)

        for name <- ~w(a.jpg b.png c.gif d.webp e.avif f.heic g.heif) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        for name <- ~w(v.mp4 v.mkv v.webm v.mov v.m4v) do
          File.write!(Path.join(tmp_dir, name), "data")
        end

        files = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert length(files) == 12

        assert Enum.all?(files, fn p ->
                 Path.extname(p) in ~w(.jpg .png .gif .webp .avif .heic .heif .mp4 .mkv .webm .mov .m4v)
               end)
      end)
    end

    @tag :tmp_dir
    test "returns supported files regardless of the upload size limit", %{tmp_dir: tmp_dir} do
      preserve_env(fn ->
        Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 4)
        File.write!(Path.join(tmp_dir, "small.jpg"), "ok")
        File.write!(Path.join(tmp_dir, "large.jpg"), "toolarge!")

        files = Lolek.GalleryDownloader.list_media_files(tmp_dir)
        assert Enum.map(files, &Path.basename/1) == ["large.jpg", "small.jpg"]
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
      for ext <- ~w(.jpg .jpeg .png .gif .webp .avif .heic .heif) do
        refute Lolek.GalleryDownloader.video_file?("photo#{ext}"),
               "expected false for #{ext}"
      end
    end
  end

  describe "image_file?/1" do
    test "returns true for all supported image extensions" do
      for ext <- ~w(.jpg .jpeg .png .gif .webp .avif .heic .heif) do
        assert Lolek.GalleryDownloader.image_file?("photo#{ext}"),
               "expected true for #{ext}"
      end
    end

    test "is case-insensitive" do
      assert Lolek.GalleryDownloader.image_file?("PHOTO.HEIC")
      assert Lolek.GalleryDownloader.image_file?("Photo.Heif")
    end

    test "returns false for video extensions" do
      for ext <- ~w(.mp4 .mkv .webm .mov .m4v) do
        refute Lolek.GalleryDownloader.image_file?("video#{ext}"),
               "expected false for #{ext}"
      end
    end
  end

  describe "parse_text_post/1" do
    test "reads Twitter post text from the content field" do
      output = Jason.encode!([[2, %{"content" => "  hello\r\nworld  "}]])
      assert {:ok, "hello\nworld"} = Lolek.GalleryDownloader.parse_text_post(output)
    end

    test "reads Bluesky post text from the text field" do
      output = Jason.encode!([[2, %{"text" => "bluesky post"}]])
      assert {:ok, "bluesky post"} = Lolek.GalleryDownloader.parse_text_post(output)
    end

    test "rejects posts with media URLs" do
      output = Jason.encode!([[2, %{"content" => "text"}], [3, "https://x.test/a.jpg", %{}]])
      assert {:error, :post_has_media} = Lolek.GalleryDownloader.parse_text_post(output)
    end

    test "rejects posts without text" do
      assert {:error, :no_text_post} =
               Lolek.GalleryDownloader.parse_text_post(Jason.encode!([[2, %{"content" => " "}]]))

      assert {:error, :no_text_post} = Lolek.GalleryDownloader.parse_text_post("[]")
    end

    test "returns gallery-dl errors" do
      output = Jason.encode!([[-1, %{"error" => "HttpError"}]])

      assert {:error, {:gallery_dl_error, %{"error" => "HttpError"}}} =
               Lolek.GalleryDownloader.parse_text_post(output)
    end

    test "rejects invalid output" do
      assert {:error, _reason} = Lolek.GalleryDownloader.parse_text_post("not json")
      assert {:error, :invalid_gallery_dl_output} = Lolek.GalleryDownloader.parse_text_post("{}")
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
