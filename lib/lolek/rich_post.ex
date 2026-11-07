defmodule Lolek.RichPost do
  @moduledoc """
  Builds a Telegram rich message (`ExGram.Model.InputRichMessage`) that looks like the
  source post: author header, text with links, media, linked posts, and a footer.
  """

  @gif_extensions ~w(.gif)
  @photo_extensions ~w(.jpg .jpeg .png .webp .avif)
  @max_text_chars 20_000
  @max_linked_text_chars 2_000
  @max_remote_media 4
  @separator " · "

  @platform_names %{
    twitter: "X",
    bluesky: "Bluesky",
    threads: "Threads",
    instagram: "Instagram",
    tiktok: "TikTok",
    facebook: "Facebook",
    youtube: "YouTube",
    coub: "Coub"
  }

  @stat_icons [
    replies: "💬",
    reposts: "🔁",
    quotes: "❝",
    likes: "♥",
    views: "👁",
    bookmarks: "🔖"
  ]

  @typedoc """
  A downloaded media file: `source` is a prepared upload or a Telegram file_id, `ext`
  is the file extension, and `options` has the video width, height, and duration.
  """
  @type media :: %{source: term(), ext: String.t(), options: keyword()}

  @type option ::
          {:details, boolean()}
          | {:requester, String.t() | nil}
          | {:remote_media, boolean()}

  @doc """
  Builds the rich message.

  Options:
    * `:details` - show the author, text, linked posts, date, and stats (default `true`)
    * `:requester` - the "requested by" line, or nil
    * `:remote_media` - show media of linked posts by URL (default `true`)
  """
  @spec build(Lolek.Post.t() | nil, [media()], [option()]) :: ExGram.Model.InputRichMessage.t()
  def build(post, media, opts \\ []) do
    post = post || Lolek.Post.empty()
    details? = Keyword.get(opts, :details, true)
    opts = Keyword.put(opts, :details, details?)
    {media_html, input_media} = media_block(media, container(post.platform))

    body =
      post
      |> sections(details?)
      |> Enum.map(&section(&1, post, media_html, opts))
      |> IO.iodata_to_binary()

    html = separate(body, post |> footer(opts) |> IO.iodata_to_binary())

    %ExGram.Model.InputRichMessage{
      html: html,
      media: if(input_media == [], do: nil, else: input_media),
      skip_entity_detection: true
    }
  end

  @spec sections(Lolek.Post.t(), boolean()) :: [atom()]
  defp sections(_post, false), do: [:media]

  defp sections(%Lolek.Post{platform: platform}, true)
       when platform in [:twitter, :bluesky, :threads, :facebook] do
    [:header, :reply_to, :text, :link_card, :media, :quoted]
  end

  defp sections(%Lolek.Post{platform: :instagram}, true),
    do: [:header, :location, :media, :text]

  defp sections(%Lolek.Post{platform: :tiktok}, true),
    do: [:media, :header, :text, :music]

  defp sections(_post, true), do: [:media, :title, :header, :text, :link_card]

  # Rich messages have no margins, so a divider keeps the footer apart from the post.
  @spec separate(String.t(), String.t()) :: String.t()
  defp separate(body, footer) do
    body = String.trim_trailing(body, "<hr/>")

    case {body, footer} do
      {"", footer} -> footer
      {body, ""} -> body
      {body, footer} -> body <> "<hr/>" <> footer
    end
  end

  @spec container(Lolek.Post.platform()) :: :collage | :slideshow
  defp container(platform) when platform in [:instagram, :tiktok], do: :slideshow
  defp container(_platform), do: :collage

  @spec section(atom(), Lolek.Post.t(), iodata(), keyword()) :: iodata()
  defp section(:media, _post, media_html, _opts), do: media_html

  defp section(:header, post, _media_html, _opts) do
    case header(post) do
      [] -> []
      header -> [header, "<hr/>"]
    end
  end

  defp section(:text, post, _media_html, _opts), do: text(post, @max_text_chars)

  defp section(:reply_to, %Lolek.Post{reply_to: nil}, _media_html, _opts), do: []

  defp section(:reply_to, %Lolek.Post{reply_to: %Lolek.Post{text: nil} = parent}, _, _opts) do
    case parent.author do
      %{handle: handle} when is_binary(handle) ->
        ["<p>↩️ Replying to ", link(parent.author.url || parent.url, "@" <> handle), "</p>"]

      _ ->
        []
    end
  end

  defp section(:reply_to, %Lolek.Post{reply_to: parent}, _media_html, opts),
    do: linked_post(parent, opts)

  defp section(:quoted, %Lolek.Post{quoted: nil}, _media_html, _opts), do: []

  defp section(:quoted, %Lolek.Post{quoted: quoted}, _media_html, opts),
    do: linked_post(quoted, opts)

  defp section(:link_card, %Lolek.Post{link_card: nil}, _media_html, _opts), do: []

  defp section(:link_card, %Lolek.Post{link_card: card}, _media_html, _opts) do
    title = card.title || card.url
    host = URI.parse(card.url).host

    [
      "<blockquote><p><b>",
      link(card.url, title),
      "</b></p>",
      if(card.description, do: ["<p>", escape(card.description), "</p>"], else: []),
      if(host, do: ["<p>", escape(host), "</p>"], else: []),
      "</blockquote>"
    ]
  end

  defp section(:location, %Lolek.Post{extra: %{location: location}}, _media_html, _opts),
    do: ["<p>📍 ", escape(location), "</p>"]

  defp section(:music, %Lolek.Post{extra: %{music: music}}, _media_html, _opts),
    do: ["<p>♫ ", escape(music), "</p>"]

  defp section(:title, %Lolek.Post{title: title, text: text}, _media_html, _opts)
       when is_binary(title) do
    if is_binary(text) and String.starts_with?(text, String.trim_trailing(title, ".")),
      do: [],
      else: ["<h3>", escape(title), "</h3>"]
  end

  defp section(_name, _post, _media_html, _opts), do: []

  # A quoted post or a parent post, shown as an expandable quotation: Telegram shows the
  # first lines, and the reader can open the rest.
  @spec linked_post(Lolek.Post.t(), keyword()) :: iodata()
  defp linked_post(post, opts) do
    remote_media =
      if Keyword.get(opts, :remote_media, true),
        do: remote_media_block(post.media),
        else: []

    body = [header(post), text(post, @max_linked_text_chars), remote_media]

    if IO.iodata_length(body) == 0 do
      []
    else
      footer =
        if post.url, do: ["<p>", link(post.url, platform_name(post)), "</p>"], else: []

      ["<blockquote expandable>", body, footer, "</blockquote>"]
    end
  end

  @spec header(Lolek.Post.t()) :: iodata()
  defp header(%Lolek.Post{author: nil}), do: []

  defp header(%Lolek.Post{author: author}) do
    verified = if author.verified, do: " ✓", else: ""

    case {author.name, author.handle} do
      {nil, handle} ->
        ["<p><b>", link(author.url, "@" <> handle), "</b>", verified, "</p>"]

      {name, nil} ->
        ["<p><b>", link(author.url, name), "</b>", verified, "</p>"]

      {name, handle} ->
        [
          "<p><b>",
          escape(name),
          "</b>",
          verified,
          @separator,
          link(author.url, "@" <> handle),
          "</p>"
        ]
    end
  end

  @spec text(Lolek.Post.t(), pos_integer()) :: iodata()
  defp text(%Lolek.Post{text: nil}, _max_chars), do: []

  defp text(%Lolek.Post{text: text, facets: facets, platform: platform}, max_chars) do
    {text, facets} = truncate(text, facets, max_chars)

    text
    |> Lolek.RichPost.Linkify.segments(facets, platform)
    |> Enum.map(fn
      {:text, value} -> escape(value)
      {:link, label, url} -> link(url, label)
    end)
    |> IO.iodata_to_binary()
    |> String.replace(["\r\n", "\r"], "\n")
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&["<p>", String.replace(&1, "\n", "<br>"), "</p>"])
  end

  @spec truncate(String.t(), [Lolek.Post.facet()] | nil, pos_integer()) ::
          {String.t(), [Lolek.Post.facet()] | nil}
  defp truncate(text, facets, max_chars) do
    if String.length(text) <= max_chars do
      {text, facets}
    else
      cut = String.slice(text, 0, max_chars)
      size = byte_size(cut)
      facets = facets && Enum.filter(facets, &(&1.stop <= size))
      {cut <> "…", facets}
    end
  end

  # The post details and the requester line are separate footers with a divider between them.
  @spec footer(Lolek.Post.t(), keyword()) :: iodata()
  defp footer(post, opts) do
    details =
      if Keyword.fetch!(opts, :details),
        do: footer_block([date_and_source(post), stats(post.stats)]),
        else: []

    requester =
      case Keyword.get(opts, :requester) do
        requester when is_binary(requester) -> footer_block([escape(requester)])
        _ -> []
      end

    [details, requester]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse("<hr/>")
  end

  @spec footer_block([iodata()]) :: iodata()
  defp footer_block(lines) do
    case Enum.reject(lines, &(IO.iodata_length(&1) == 0)) do
      [] -> []
      lines -> ["<footer>", Enum.intersperse(lines, "<br>"), "</footer>"]
    end
  end

  @spec date_and_source(Lolek.Post.t()) :: iodata()
  defp date_and_source(post) do
    date =
      case post.published_at do
        %DateTime{} = datetime ->
          [
            ~s(<tg-time unix="#{DateTime.to_unix(datetime)}" format="Dt">),
            Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC"),
            "</tg-time>"
          ]

        nil ->
          []
      end

    source = if post.url, do: link(post.url, platform_name(post)), else: []

    [date, source]
    |> Enum.reject(&(IO.iodata_length(&1) == 0))
    |> Enum.intersperse(@separator)
  end

  @spec stats(Lolek.Post.stats()) :: iodata()
  defp stats(stats) do
    @stat_icons
    |> Enum.flat_map(fn {key, icon} ->
      case Map.get(stats, key) do
        count when is_integer(count) and count > 0 -> [[icon, " ", compact_count(count)]]
        _ -> []
      end
    end)
    |> Enum.intersperse(@separator)
  end

  @doc "Formats a count the way social networks do: 1234 is 1.2K, 2500000 is 2.5M."
  @spec compact_count(non_neg_integer()) :: String.t()
  def compact_count(count) when count < 1_000, do: Integer.to_string(count)
  def compact_count(count) when count < 1_000_000, do: compact(count / 1_000, "K")
  def compact_count(count) when count < 1_000_000_000, do: compact(count / 1_000_000, "M")
  def compact_count(count), do: compact(count / 1_000_000_000, "B")

  @spec compact(float(), String.t()) :: String.t()
  defp compact(value, suffix) when value >= 100, do: "#{trunc(value)}#{suffix}"

  defp compact(value, suffix) do
    rounded = Float.floor(value * 10) / 10

    if rounded == trunc(rounded),
      do: "#{trunc(rounded)}#{suffix}",
      else: "#{:erlang.float_to_binary(rounded, decimals: 1)}#{suffix}"
  end

  @spec platform_name(Lolek.Post.t()) :: String.t()
  defp platform_name(%Lolek.Post{platform: platform, url: url}) do
    Map.get(@platform_names, platform) || (url && URI.parse(url).host) || "Source"
  end

  @spec media_block([media()], :collage | :slideshow) :: {iodata(), [struct()]}
  defp media_block(media, container) do
    entries =
      media
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> media_entry(item, "m#{index}") end)

    {visual, documents} =
      Enum.split_with(entries, fn {kind, _html, _input} -> kind != :document end)

    visual_html = Enum.map(visual, &elem(&1, 1))
    document_html = Enum.map(documents, &elem(&1, 1))

    html =
      case visual_html do
        [] -> []
        [single] -> single
        many -> wrap(many, container)
      end

    {[html, document_html], Enum.map(entries, &elem(&1, 2))}
  end

  @spec wrap(iodata(), :collage | :slideshow) :: iodata()
  defp wrap(html, :collage), do: ["<tg-collage>", html, "</tg-collage>"]
  defp wrap(html, :slideshow), do: ["<tg-slideshow>", html, "</tg-slideshow>"]

  @spec media_entry(media(), String.t()) ::
          {:photo | :video | :document, iodata(), ExGram.Model.InputRichMessageMedia.t()}
  defp media_entry(%{source: source, ext: ext} = item, id) do
    options = Map.get(item, :options, [])

    {kind, html, input} =
      cond do
        ext in @gif_extensions ->
          {:video, ~s(<video src="tg://video?id=#{id}"></video>),
           %ExGram.Model.InputMediaAnimation{type: "animation", media: source}}

        Lolek.GalleryDownloader.video_file?("x#{ext}") ->
          {:video, ~s(<video src="tg://video?id=#{id}"></video>), video_input(source, options)}

        ext in @photo_extensions ->
          {:photo, ~s(<img src="tg://photo?id=#{id}"/>),
           %ExGram.Model.InputMediaPhoto{type: "photo", media: source}}

        true ->
          {:document, ~s(<tg-document src="tg://document?id=#{id}"></tg-document>),
           %ExGram.Model.InputMediaDocument{type: "document", media: source}}
      end

    {kind, html, %ExGram.Model.InputRichMessageMedia{id: id, media: input}}
  end

  @spec video_input(term(), keyword()) :: ExGram.Model.InputMediaVideo.t()
  defp video_input(source, options) do
    %ExGram.Model.InputMediaVideo{
      type: "video",
      media: source,
      width: Keyword.get(options, :width),
      height: Keyword.get(options, :height),
      duration: Keyword.get(options, :duration),
      supports_streaming: true
    }
  end

  @spec remote_media_block([Lolek.Post.remote_media()]) :: iodata()
  defp remote_media_block(media) do
    html =
      media
      |> Enum.filter(&(&1.type == :photo))
      |> Enum.take(@max_remote_media)
      |> Enum.map(&[~s(<img src="), escape(&1.url), ~s("/>)])

    case html do
      [] -> []
      [single] -> single
      many -> wrap(many, :collage)
    end
  end

  @spec link(String.t() | nil, String.t()) :: iodata()
  defp link(nil, label), do: escape(label)
  defp link(url, label), do: [~s(<a href="), escape(url), ~s(">), escape(label), "</a>"]

  @doc "Escapes text for rich message HTML."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
