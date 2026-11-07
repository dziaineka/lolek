defmodule Lolek.RichPostTest do
  use ExUnit.Case, async: true

  @photo %{source: "photo-id", ext: ".jpg", options: []}
  @video %{source: "video-id", ext: ".mp4", options: [width: 720, height: 1280, duration: 9]}

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
    message = Lolek.RichPost.build(tweet(), [@photo, @video], requester: "alice requested")

    assert message.skip_entity_detection

    assert message.html ==
             ~s(<p><b>Jack &lt;3</b> ✓ · <a href="https://x.com/jack">@jack</a></p><hr/>) <>
               ~s(<p>Hi <a href="https://x.com/ev">@ev</a> &amp; ) <>
               ~s(<a href="https://x.com/hashtag/friends">#friends</a><br>see ) <>
               ~s(<a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a>.</p>) <>
               ~s(<p>Bye</p>) <>
               ~s(<tg-collage><img src="tg://photo?id=m0"/><video src="tg://video?id=m1"></video></tg-collage><hr/>) <>
               ~s(<footer><tg-time unix="1142974214" format="Dt">2006-03-21 20:50 UTC</tg-time> · ) <>
               ~s(<a href="https://x.com/jack/status/20">X</a><br>🔁 126K · ♥ 325K</footer>) <>
               ~s(<hr/><footer>alice requested</footer>)

    assert [
             %ExGram.Model.InputRichMessageMedia{
               id: "m0",
               media: %ExGram.Model.InputMediaPhoto{media: "photo-id"}
             },
             %ExGram.Model.InputRichMessageMedia{
               id: "m1",
               media: %ExGram.Model.InputMediaVideo{
                 media: "video-id",
                 width: 720,
                 height: 1280,
                 duration: 9,
                 supports_streaming: true
               }
             }
           ] = message.media
  end

  test "shows only the media and the requester line without details" do
    message = Lolek.RichPost.build(tweet(), [@photo], details: false, requester: "alice")

    assert message.html == ~s(<img src="tg://photo?id=m0"/><hr/><footer>alice</footer>)
  end

  test "does not repeat the divider when only the header is before the footer" do
    post = %Lolek.Post{author: Lolek.Post.author("Name", nil, nil), url: "https://example.com/p"}

    assert Lolek.RichPost.build(post, []).html ==
             ~s(<p><b>Name</b></p><hr/><footer><a href="https://example.com/p">example.com</a></footer>)
  end

  test "shows only the media without details and without a requester" do
    assert Lolek.RichPost.build(tweet(), [@photo], details: false).html ==
             ~s(<img src="tg://photo?id=m0"/>)
  end

  test "lays out Instagram posts with the media above the caption in a slideshow" do
    post = %Lolek.Post{
      platform: :instagram,
      author: Lolek.Post.author(nil, "natgeo", "https://www.instagram.com/natgeo/"),
      text: "Caption #nature",
      extra: %{location: "Yellowstone"}
    }

    html = Lolek.RichPost.build(post, [@photo, @photo]).html

    assert html ==
             ~s(<p><b><a href="https://www.instagram.com/natgeo/">@natgeo</a></b></p><hr/>) <>
               ~s(<p>📍 Yellowstone</p>) <>
               ~s(<tg-slideshow><img src="tg://photo?id=m0"/><img src="tg://photo?id=m1"/></tg-slideshow>) <>
               ~s(<p>Caption <a href="https://www.instagram.com/explore/tags/nature/">#nature</a></p>)
  end

  test "lays out TikTok posts with the video first and the music" do
    post = Lolek.Post.YtDlp.parse(fixture("tiktok_video.yt_dlp.json"))
    html = Lolek.RichPost.build(post, [@video]).html

    assert String.starts_with?(html, ~s(<video src="tg://video?id=m0"></video><p><b>Scout))
    assert html =~ "<p>♫ original sound – tiff</p>"
    assert html =~ ~s(<a href="https://www.tiktok.com/tag/foryoupage">#foryoupage</a>)
  end

  test "lays out videos with the title as a heading" do
    post = Lolek.Post.YtDlp.parse(fixture("youtube_short.yt_dlp.json"))
    html = Lolek.RichPost.build(post, [@video]).html

    assert html =~
             ~s(<video src="tg://video?id=m0"></video><h3>MET THE LOVE OF MY LIFE ON AN AIRPLANE *caught on camera*</h3>)

    assert html =~ "💬 2.3K · ♥ 91K · 👁 6.5M"
  end

  test "does not repeat a title that is the start of the text" do
    post = %Lolek.Post{platform: :generic, title: "Some text...", text: "Some text and more"}
    refute Lolek.RichPost.build(post, []).html =~ "<h3>"
  end

  test "shows the quoted post with its media and the parent post as quotations" do
    {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_quote_media.appview.json"))
    html = Lolek.RichPost.build(post, [@photo]).html

    assert html =~
             ~r{<img src="tg://photo\?id=m0"/><blockquote expandable><p><b>robdog 👾</b> · .*</blockquote><hr/><footer>}

    assert html =~ ~s(<img src="https://cdn.bsky.app/img/feed_fullsize/plain/)

    refute Lolek.RichPost.build(post, [@photo], remote_media: false).html =~
             "https://cdn.bsky.app"

    {:ok, reply} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_reply.appview.json"))
    reply_html = Lolek.RichPost.build(reply, []).html

    assert reply_html =~
             ~r{^<p><b>Bluesky</b>.*?</p><hr/><blockquote expandable><p><b>Bluesky</b>.*Mountain West}
  end

  test "shows a parent reference without text as a reply line" do
    {:ok, post} = Lolek.Post.GalleryDl.parse_messages(fixture("x_reply.gallery_dl.json"))

    assert Lolek.RichPost.build(post, []).html =~
             ~s(<p>↩️ Replying to <a href="https://x.com/NASA">@NASA</a></p>)
  end

  test "shows link cards" do
    {:ok, post} = Lolek.Post.Bluesky.parse_thread(fixture("bsky_link.appview.json"))

    assert Lolek.RichPost.build(post, []).html =~
             ~s|<blockquote><p><b><a href="https://en.wikipedia.org/wiki/Musk_(film)">Musk (film) - Wikipedia</a></b></p><p>en.wikipedia.org</p></blockquote>|
  end

  test "truncates long text" do
    post = %Lolek.Post{text: String.duplicate("a", 30_000)}
    html = Lolek.RichPost.build(post, []).html

    assert html == "<p>" <> String.duplicate("a", 20_000) <> "…</p>"
  end

  test "builds a message without a post" do
    assert Lolek.RichPost.build(nil, [@photo]).html == ~s(<img src="tg://photo?id=m0"/>)
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
