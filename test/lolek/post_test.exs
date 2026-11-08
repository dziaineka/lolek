defmodule Lolek.PostTest do
  use ExUnit.Case, async: true

  defp fixture(name) do
    Path.join("test/fixtures/posts", name) |> File.read!() |> Jason.decode!()
  end

  describe "Lolek.Post.Bluesky.parse_thread/1" do
    test "reads the author, text, stats, and the quoted post with its media" do
      {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_quote_media.appview.json"))

      assert post.platform == :bluesky
      assert post.source == :api
      assert post.url == "https://bsky.app/profile/peloriemate.net/post/3mxkb3qz4cs27"

      assert post.author == %{
               name: "maud",
               handle: "peloriemate.net",
               url: "https://bsky.app/profile/peloriemate.net",
               verified: false
             }

      assert post.text =~ "fakeposting"
      assert post.stats.likes == 21_070
      assert post.stats.reposts == 5276
      assert post.published_at == ~U[2026-10-10 19:49:31Z]

      assert %Lolek.Post{author: %{handle: "robdogdraws.bsky.social"}} = quoted = post.quoted

      assert quoted.text ==
               "Probably the coolest thing he's done next to being a potential Bomberman fan"

      assert [%{type: :photo, url: "https://cdn.bsky.app/img/feed_fullsize/" <> _}] = quoted.media
    end

    test "reads the parent post and mention facets with handles" do
      {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_reply.appview.json"))

      assert %Lolek.Post{text: "Mountain West:" <> _} = post.reply_to

      assert [first | _] = post.facets
      assert first.type == :mention
      assert first.value == "https://bsky.app/profile/calmatters.org"
      assert binary_part(post.text, first.start, first.stop - first.start) == "@calmatters.org"
    end

    test "reads link facets and link cards and skips a parent that is not found" do
      {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_link.appview.json"))

      assert post.reply_to == nil
      assert [%{type: :link, value: "https://en.wikipedia.org/wiki/Musk_(film)"}] = post.facets

      assert %{url: "https://en.wikipedia.org/wiki/Musk_(film)", title: "Musk (film) - Wikipedia"} =
               post.link_card
    end

    test "rejects other responses" do
      assert {:error, :invalid_bluesky_thread} = Lolek.Post.Bluesky.parse_thread(%{})
    end

    test "converts post URLs to AT URIs" do
      assert {:ok, "at://bsky.app/app.bsky.feed.post/3mzhhvhjfwk22"} =
               Lolek.Post.Bluesky.at_uri("https://bsky.app/profile/bsky.app/post/3mzhhvhjfwk22")

      assert {:error, :not_a_bluesky_post} =
               Lolek.Post.Bluesky.at_uri("https://bsky.app/profile/bsky.app")
    end
  end

  describe "Lolek.Post.Threads" do
    test "reads the author, text, date, and counters of a post" do
      %{"DfFVRsRDiu4" => node} = fixture("threads_post.page.json")
      post = Lolek.Post.Threads.parse(node)

      assert post.platform == :threads
      assert post.url == "https://www.threads.com/@eugenia_warsaw/post/DfFVRsRDiu4"

      assert %{
               handle: "eugenia_warsaw",
               verified: true,
               url: "https://www.threads.com/@eugenia_warsaw"
             } =
               post.author

      assert post.author.name =~ "Риелтор Варшава"
      # The object replacement character at the end of the caption is removed.
      assert post.text ==
               "Трехкомнатные квартиры площадью… 38м2🫣🫣🫣\nДумала что трешка 45м2 это предел, но оказывается бывает и не такое)"

      assert post.facets == nil
      assert post.published_at == ~U[2026-10-29 15:30:02Z]
      assert post.stats == %{likes: 13, replies: 7, reposts: 1, quotes: 0}
      assert post.reply_to == nil
      assert length(post.media) == 2
    end

    test "reads the author of the parent post of a reply" do
      %{"DfFaK0lgNpV" => node} = fixture("threads_post.page.json")

      assert %Lolek.Post{author: %{handle: "eugenia_warsaw"}, text: nil} =
               Lolek.Post.Threads.parse(node).reply_to
    end

    test "reads links, mentions, the quoted post, and the link card" do
      quoted = %{
        "code" => "Q1",
        "user" => %{"username" => "quoted_user", "full_name" => "Quoted"},
        "caption" => %{"text" => "Quoted text \u{FFFC}"},
        "image_versions2" => %{"candidates" => [%{"url" => "https://cdn.example/q.jpg"}]}
      }

      node = %{
        "code" => "P1",
        "user" => %{"username" => "author", "full_name" => "Author"},
        "text_post_app_info" => %{
          "text_fragments" => %{
            "fragments" => [
              %{"plaintext" => " Hi "},
              %{
                "plaintext" => "@friend",
                "mention_fragment" => %{"mentioned_user_info" => %{"username" => "friend"}}
              },
              %{"plaintext" => ", see "},
              %{
                "plaintext" => "example.com",
                "link_fragment" => %{"uri" => "https://example.com/a"}
              },
              %{"plaintext" => " \u{FFFC}"}
            ]
          },
          "share_info" => %{"quoted_post" => quoted},
          "link_preview_attachment" => %{
            "url" => "https://example.com/a",
            "title" => "Example",
            "display_url" => "example.com"
          }
        }
      }

      post = Lolek.Post.Threads.parse(node)

      assert post.text == "Hi @friend, see example.com"

      assert [
               %{start: 3, stop: 10, type: :mention, value: "https://www.threads.com/@friend"},
               %{start: 16, stop: 27, type: :link, value: "https://example.com/a"}
             ] = post.facets

      assert %Lolek.Post{text: "Quoted text", author: %{handle: "quoted_user"}} = post.quoted
      assert [%{type: :photo, url: "https://cdn.example/q.jpg"}] = post.quoted.media
      assert %{url: "https://example.com/a", title: "Example"} = post.link_card
    end

    test "does not show the media of another post as a quoted post" do
      node = %{
        "code" => "P1",
        "user" => %{"username" => "author"},
        "caption" => %{"text" => "Look"},
        "text_post_app_info" => %{
          "share_info" => %{
            "quoted_post" => nil,
            "quoted_attachment_post" => %{
              "code" => "Q1",
              "user" => %{"username" => "other"},
              "video_versions" => [%{"url" => "https://cdn.example/q.mp4"}]
            }
          }
        }
      }

      assert %Lolek.Post{text: "Look", quoted: nil} = Lolek.Post.Threads.parse(node)
    end

    test "finds the copy of the post that has the author in the page data" do
      documents = [
        %{"require" => [%{"code" => "P1", "caption" => nil}]},
        %{
          "data" => %{
            "post" => %{"code" => "P1", "user" => %{"username" => "a"}, "like_count" => 1}
          }
        }
      ]

      assert %{"like_count" => 1} = Lolek.Post.Threads.find_post(documents, "P1")
      assert Lolek.Post.Threads.find_post(documents, "P2") == nil
    end
  end

  describe "Lolek.Post.GalleryDl.parse_messages/1" do
    test "reads tweets: display name, screen name, stats, and the quote reference" do
      {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("x_gallery.gallery_dl.json"))

      assert post.platform == :twitter
      assert post.url == "https://x.com/NASA/status/2119089554837979631"

      assert post.author == %{
               name: "NASA",
               handle: "NASA",
               url: "https://x.com/NASA",
               verified: false
             }

      assert post.stats == %{
               likes: 658,
               reposts: 100,
               replies: 69,
               quotes: 11,
               views: 223_819,
               bookmarks: 13
             }

      assert post.published_at == ~U[2026-11-07 15:28:15Z]
      assert post.extra == %{}
      assert length(post.media) == 4
    end

    test "reads the quoted tweet that gallery-dl gives with the quoted option" do
      {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("x_quote.gallery_dl.json"))

      assert post.author.handle == "sourceloc"
      assert String.starts_with?(post.text, "> Omarchy releases support for ARM Macs")

      assert [%{type: :photo, url: "https://pbs.twimg.com/media/HWh0PRsWsAAKHo8" <> _}] =
               post.media

      assert %Lolek.Post{author: %{handle: "sysxplore"}, text: "Asahi Linux is moving" <> _} =
               post.quoted

      assert [%{type: :photo, url: "https://pbs.twimg.com/media/HWgVl1UXIAEY4gi" <> _}] =
               post.quoted.media
    end

    test "removes the leading reply mentions and keeps the parent reference" do
      {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("x_reply.gallery_dl.json"))

      assert String.starts_with?(post.text, "NASA astronaut @Astro_Anil")
      assert post.extra == %{reply_id: "2118436047361393096"}

      assert %Lolek.Post{
               text: nil,
               author: %{handle: "NASA"},
               url: "https://x.com/NASA/status/2118436047361393096"
             } = post.reply_to
    end

    test "reads TikTok posts with the music" do
      {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("tiktok_video.gallery_dl.json"))

      assert post.author.name == "Scout, Suki & Stella"
      assert post.author.handle == "scout2015"
      assert post.author.verified
      assert post.stats.likes == 35_200
      assert post.stats.bookmarks == 650
      assert post.extra.music == "original sound – tiff"
    end

    test "reads Instagram posts" do
      metadata = %{
        "category" => "instagram",
        "username" => "natgeo",
        "fullname" => "National Geographic",
        "description" => "A photo #nature",
        "likes" => 1200,
        "date" => "2026-01-02 03:04:05",
        "post_url" => "https://www.instagram.com/p/abc/",
        "location" => %{"name" => "Yellowstone"}
      }

      assert {:ok, post} = Lolek.Post.GalleryDl.parse_messages([[2, metadata]])
      assert post.author.url == "https://www.instagram.com/natgeo/"
      assert post.extra.location == "Yellowstone"
      assert post.stats == %{likes: 1200}
    end

    test "returns an error without metadata" do
      assert {:error, :no_post_metadata} = Lolek.Post.GalleryDl.parse_messages([[-1, %{}]])
    end
  end

  describe "Lolek.Post.YtDlp.parse/2" do
    test "reads TikTok handles from the uploader and names from the channel" do
      post = Lolek.Post.YtDlp.parse(fixture("tiktok_video.yt_dlp.json"))

      assert post.author.name == "Scout, Suki & Stella"
      assert post.author.handle == "scout2015"
      assert post.extra.music == "original sound – tiff"
      assert post.stats.replies == 5622
    end

    test "removes the media link and the reply mentions of tweets" do
      post = Lolek.Post.YtDlp.parse(fixture("x_reply.yt_dlp.json"))

      assert post.author.url == "https://x.com/NASA"
      refute post.text =~ "t.co"
      assert String.starts_with?(post.text, "NASA astronaut")
    end

    test "reads YouTube channel handles" do
      post = Lolek.Post.YtDlp.parse(fixture("youtube_short.yt_dlp.json"))

      assert post.platform == :youtube
      assert post.author.handle == "AllieSchnackyArmstrong"
      assert post.author.verified
      assert post.title == "MET THE LOVE OF MY LIFE ON AN AIRPLANE *caught on camera*"
    end
  end

  describe "merge/2" do
    test "prefers the fields of the source with the higher priority" do
      yt_dlp = Lolek.Post.YtDlp.parse(fixture("tiktok_video.yt_dlp.json"))

      {:ok, gallery} =
        Lolek.Post.GalleryDl.parse_messages(fixture("tiktok_video.gallery_dl.json"))

      merged = Lolek.Post.merge(yt_dlp, gallery)

      assert merged.source == :gallery_dl
      assert merged.stats.bookmarks == 650
      assert merged.title == yt_dlp.title
    end

    test "keeps the facets with the text that they belong to" do
      api = %Lolek.Post{source: :api, text: nil}
      gallery = %Lolek.Post{source: :gallery_dl, text: "text", facets: []}

      assert %Lolek.Post{text: "text", facets: []} = Lolek.Post.merge(api, gallery)
    end
  end

  test "to_map/1 and from_map/1 keep all fields" do
    {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_reply.appview.json"))

    post = %{
      post
      | extra: %{music: "song"},
        link_card: %{url: "https://a", title: nil, description: "d"}
    }

    json = post |> Lolek.Post.to_map() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^post} = Lolek.Post.from_map(json)
  end

  test "from_map/1 rejects invalid maps" do
    assert {:error, :invalid_post} = Lolek.Post.from_map(%{"text" => 5})
    assert {:error, :invalid_post} = Lolek.Post.from_map("text")
  end

  test "parse_datetime/1 reads Unix time, ISO dates, gallery-dl dates, and yt-dlp dates" do
    assert Lolek.Post.parse_datetime(0) == nil
    assert Lolek.Post.parse_datetime(1_564_234_358) == ~U[2019-07-27 13:32:38Z]
    assert Lolek.Post.parse_datetime("1564234358") == ~U[2019-07-27 13:32:38Z]
    assert Lolek.Post.parse_datetime("2026-11-04T04:03:40.249Z") == ~U[2026-11-04 04:03:40Z]
    assert Lolek.Post.parse_datetime("2026-11-04 04:03:40") == ~U[2026-11-04 04:03:40Z]
    assert Lolek.Post.parse_datetime("20261105") == ~U[2026-11-05 00:00:00Z]
    assert Lolek.Post.parse_datetime("never") == nil
  end

  test "platform_from_url/1 knows the supported hosts" do
    assert Lolek.Post.platform_from_url("https://x.com/a/status/1") == :twitter
    assert Lolek.Post.platform_from_url("https://mobile.twitter.com/a") == :twitter
    assert Lolek.Post.platform_from_url("https://vm.tiktok.com/abc") == :tiktok
    assert Lolek.Post.platform_from_url("https://www.threads.net/@a/post/b") == :threads
    assert Lolek.Post.platform_from_url("https://notx.com/a") == :generic
  end
end
