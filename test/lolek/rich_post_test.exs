defmodule Lolek.RichPostTest do
  use ExUnit.Case, async: true

  @photo %{source: "photo-id", ext: ".jpg", options: []}
  @video %{source: "video-id", ext: ".mp4", options: [width: 720, height: 1280, duration: 9]}
  @doc_file %{source: "doc-id", ext: ".txt", options: []}

  defp html(post, media, opts \\ []) do
    post |> Lolek.RichPost.build(media, opts) |> elem(0) |> Lolek.Test.RichMarkup.render()
  end

  defp fixture(name) do
    Path.join("test/fixtures/posts", name) |> File.read!() |> Jason.decode!()
  end

  defp tweet do
    %Lolek.Post{
      platform: :twitter,
      url: "https://x.com/jack/status/20",
      author: Lolek.Post.author("Jack <3", "jack", "https://x.com/jack", true),
      text: "Hi @ev & #friends\nsee https://example.com/a?b=1&c=2.\n\nBye",
      published_at: ~U[2006-03-21 20:50:14Z],
      stats: %{likes: 325_587, reposts: 126_471, replies: 0}
    }
  end

  test "lays out a tweet like X: header, text, collage, footer" do
    {message, media_indexes} =
      Lolek.RichPost.build(tweet(), [@photo, @video], requester: "alice requested")

    assert message.skip_entity_detection
    assert media_indexes == [4]

    assert Lolek.Test.RichMarkup.render(message) ==
             ~s(<p><b>Jack <3</b> ✓ · <a href="https://x.com/jack">@jack</a></p><hr/>) <>
               ~s(<p>Hi <a href="https://x.com/ev">@ev</a> & ) <>
               ~s(<a href="https://x.com/hashtag/friends">#friends</a><br>see ) <>
               ~s(<a href="https://example.com/a?b=1&c=2">https://example.com/a?b=1&c=2</a>.</p>) <>
               ~s(<p>Bye</p>) <>
               ~s(<tg-collage><img src="photo-id"/><video src="video-id"/></tg-collage><hr/>) <>
               ~s(<footer><tg-time unix="1142974214" format="Dt">2006-03-21 20:50 UTC</tg-time> · ) <>
               ~s(<a href="https://x.com/jack/status/20">X</a><br>🔁 126K · ♥ 325K</footer>) <>
               ~s(<hr/><footer>alice requested</footer>)

    assert %ExGram.Model.InputRichBlockCollage{
             blocks: [
               %ExGram.Model.InputRichBlockPhoto{photo: %ExGram.Model.InputMediaPhoto{}},
               %ExGram.Model.InputRichBlockVideo{
                 video: %ExGram.Model.InputMediaVideo{
                   media: "video-id",
                   width: 720,
                   height: 1280,
                   duration: 9,
                   supports_streaming: true
                 }
               }
             ]
           } = Enum.at(message.blocks, 4)
  end

  test "returns the file_ids of the uploaded media from the sent blocks" do
    {_message, media_indexes} = Lolek.RichPost.build(%Lolek.Post{}, [@photo, @photo, @doc_file])
    assert media_indexes == [0, 1]

    sent = [
      %ExGram.Model.RichBlockCollage{
        blocks: [
          %ExGram.Model.RichBlockPhoto{
            photo: [
              %ExGram.Model.PhotoSize{file_id: "small"},
              %ExGram.Model.PhotoSize{file_id: "p1"}
            ]
          },
          %ExGram.Model.RichBlockPhoto{photo: [%ExGram.Model.PhotoSize{file_id: "p2"}]}
        ]
      },
      %ExGram.Model.RichBlockDocument{document: %ExGram.Model.Document{file_id: "d1"}},
      %ExGram.Model.RichBlockPhoto{photo: [%ExGram.Model.PhotoSize{file_id: "remote"}]}
    ]

    assert Lolek.RichPost.file_ids(sent, media_indexes) == ["p1", "p2", "d1"]
  end

  test "shows GIFs as animations and other files as documents after the visual media" do
    {message, media_indexes} =
      Lolek.RichPost.build(nil, [@doc_file, %{source: "gif-id", ext: ".gif", options: []}])

    assert Lolek.Test.RichMarkup.render(message) ==
             ~s(<animation src="gif-id"/><tg-document src="doc-id"/>)

    assert media_indexes == [0, 1]
  end

  test "shows only the media and the requester line without details" do
    assert html(tweet(), [@photo], details: false, requester: "alice") ==
             ~s(<img src="photo-id"/><hr/><footer>alice</footer>)
  end

  test "does not repeat the divider when only the header is before the footer" do
    post = %Lolek.Post{author: Lolek.Post.author("Name", nil, nil), url: "https://example.com/p"}

    assert html(post, []) ==
             ~s(<p><b>Name</b></p><hr/><footer><a href="https://example.com/p">example.com</a></footer>)
  end

  test "shows only the media without details and without a requester" do
    assert html(tweet(), [@photo], details: false) ==
             ~s(<img src="photo-id"/>)
  end

  test "lays out Instagram posts with the media above the caption in a slideshow" do
    post = %Lolek.Post{
      platform: :instagram,
      author: Lolek.Post.author(nil, "natgeo", "https://www.instagram.com/natgeo/"),
      text: "Caption #nature",
      extra: %{location: "Yellowstone"}
    }

    html = html(post, [@photo, @photo])

    assert html ==
             ~s(<p><b><a href="https://www.instagram.com/natgeo/">@natgeo</a></b></p><hr/>) <>
               ~s(<p>📍 Yellowstone</p>) <>
               ~s(<tg-slideshow><img src="photo-id"/><img src="photo-id"/></tg-slideshow>) <>
               ~s(<p>Caption <a href="https://www.instagram.com/explore/tags/nature/">#nature</a></p>)
  end

  test "lays out TikTok posts with the video first and the music" do
    post = Lolek.Post.YtDlp.parse(fixture("tiktok_video.yt_dlp.json"))
    html = html(post, [@video])

    assert String.starts_with?(html, ~s(<video src="video-id"/><p><b>Scout))
    assert html =~ "<p>♫ original sound – tiff</p>"
    assert html =~ ~s(<a href="https://www.tiktok.com/tag/foryoupage">#foryoupage</a>)
  end

  test "lays out videos with the title as a heading" do
    post = Lolek.Post.YtDlp.parse(fixture("youtube_short.yt_dlp.json"))
    html = html(post, [@video])

    assert html =~
             ~s(<video src="video-id"/><h3>MET THE LOVE OF MY LIFE ON AN AIRPLANE *caught on camera*</h3>)

    assert html =~ "💬 2.3K · ♥ 91K · 👁 6.5M"
  end

  test "does not repeat a title that is the start of the text" do
    post = %Lolek.Post{platform: :generic, title: "Some text...", text: "Some text and more"}
    refute html(post, []) =~ "<h3>"
  end

  test "shows the quoted post with its media and the parent post as quotations" do
    {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_quote_media.appview.json"))
    html = html(post, [@photo])

    assert html =~
             ~r{<img src="photo-id"/><blockquote><p><b>robdog 👾</b> · .*</p><p>Probably .*</p><img src="https://cdn.bsky.app/[^"]+"/><p><a href="https://bsky.app/profile/robdogdraws.bsky.social/post/3mxk4ubvur22l">Bluesky</a></p></blockquote><hr/><footer>}

    assert html =~ ~s(<img src="https://cdn.bsky.app/img/feed_fullsize/plain/)

    refute html(post, [@photo], remote_media: false) =~
             "https://cdn.bsky.app"

    {:ok, reply} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_reply.appview.json"))
    reply_html = html(reply, [])

    assert reply_html =~
             ~r{^<p><b>Bluesky</b>.*?</p><hr/><blockquote><p><b>Bluesky</b>.*?</p><p>Mountain West}
  end

  test "shows a parent reference without text as a reply line" do
    {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("x_reply.gallery_dl.json"))

    assert html(post, []) =~
             ~s(<p>↩️ Replying to <a href="https://x.com/NASA">@NASA</a></p>)
  end

  test "shows link cards" do
    {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_link.appview.json"))

    assert html(post, []) =~
             ~s|<blockquote><p><b><a href="https://en.wikipedia.org/wiki/Musk_(film)">Musk (film) - Wikipedia</a></b></p><p>en.wikipedia.org</p></blockquote>|
  end

  test "truncates long text" do
    post = %Lolek.Post{text: String.duplicate("a", 30_000)}
    html = html(post, [])

    assert html == "<p>" <> String.duplicate("a", 20_000) <> "…</p>"
  end

  test "builds a message without a post" do
    assert html(nil, [@photo]) == ~s(<img src="photo-id"/>)
  end

  test "compact_count/1 formats counts like social networks" do
    assert Lolek.RichPost.compact_count(999) == "999"
    assert Lolek.RichPost.compact_count(1_000) == "1K"
    assert Lolek.RichPost.compact_count(1_250) == "1.2K"
    assert Lolek.RichPost.compact_count(98_765) == "98.7K"
    assert Lolek.RichPost.compact_count(223_819) == "223K"
    assert Lolek.RichPost.compact_count(6_566_291) == "6.5M"
    assert Lolek.RichPost.compact_count(2_000_000_000) == "2B"
  end

  describe "Lolek.RichPost.Linkify" do
    test "does not link mentions and hashtags of unknown platforms" do
      assert Lolek.RichPost.Linkify.segments("@a #b https://c.d", nil, :generic) == [
               {:text, "@a #b "},
               {:link, "https://c.d", "https://c.d"}
             ]
    end

    test "does not take e-mail addresses, anchors, and numbers as mentions or hashtags" do
      assert Lolek.RichPost.Linkify.facets("mail a@b.com, page#top, #1", :twitter) == []
    end

    test "links Bluesky handles with dots" do
      assert [%{value: "https://bsky.app/profile/a.bsky.social"}] =
               Lolek.RichPost.Linkify.facets("hi @a.bsky.social.", :bluesky)
    end

    test "uses the given facets" do
      facets = [%{start: 0, stop: 4, type: :link, value: "https://x"}]

      assert Lolek.RichPost.Linkify.segments("link text", facets, :bluesky) == [
               {:link, "link", "https://x"},
               {:text, " text"}
             ]
    end
  end
end
