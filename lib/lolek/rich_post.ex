defmodule Lolek.RichPost do
  @moduledoc """
  Builds a Telegram rich message (`ExGram.Model.InputRichMessage`) from rich blocks. The
  message looks like the source post: author header, text with links, media, linked
  posts, and a footer.
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

  @typedoc "Rich text: a string, a rich text object, or a list of them."
  @type rich_text :: String.t() | struct() | [rich_text()]

  @type option ::
          {:details, boolean()}
          | {:requester, String.t() | nil}
          | {:remote_media, boolean()}

  @doc """
  Builds the rich message. Returns the message and the indexes of the top-level blocks
  that hold the given media, in the order of the media. Put visual media (photos,
  videos, animations) before other files: other files are separate document blocks
  after the visual media.

  Options:
    * `:details` - show the author, text, linked posts, date, and stats (default `true`)
    * `:requester` - the "requested by" line, or nil
    * `:remote_media` - show media of linked posts by URL (default `true`)
  """
  @spec build(Lolek.Post.t() | nil, [media()], [option()]) ::
          {ExGram.Model.InputRichMessage.t(), [non_neg_integer()]}
  def build(post, media, opts \\ []) do
    post = post || Lolek.Post.empty()
    details? = Keyword.get(opts, :details, true)
    opts = Keyword.put(opts, :details, details?)
    media_blocks = media_blocks(media, container(post.platform))

    sections =
      post
      |> sections(details?)
      |> Enum.map(fn
        :media -> Enum.map(media_blocks, &{:media, &1})
        name -> name |> section(post, opts) |> Enum.map(&{:other, &1})
      end)
      |> List.flatten()
      |> separate(post |> footer(opts) |> Enum.map(&{:other, &1}))

    blocks = Enum.map(sections, &elem(&1, 1))

    media_indexes =
      sections
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:media, _block}, index} -> [index]
        _ -> []
      end)

    {%ExGram.Model.InputRichMessage{blocks: blocks, skip_entity_detection: true}, media_indexes}
  end

  @doc """
  Returns the file_ids of the uploaded media from the blocks of a sent rich message.
  `media_indexes` comes from `build/3`.
  """
  @spec file_ids([struct()], [non_neg_integer()]) :: [String.t()]
  def file_ids(blocks, media_indexes) do
    Enum.flat_map(media_indexes, fn index ->
      case Enum.at(blocks, index) do
        nil -> []
        block -> block_file_ids(block)
      end
    end)
  end

  @spec block_file_ids(term()) :: [String.t()]
  defp block_file_ids(%ExGram.Model.RichBlockPhoto{photo: [_ | _] = sizes}),
    do: [List.last(sizes).file_id]

  defp block_file_ids(%ExGram.Model.RichBlockVideo{video: %ExGram.Model.Video{file_id: id}}),
    do: [id]

  defp block_file_ids(%ExGram.Model.RichBlockAnimation{
         animation: %ExGram.Model.Animation{file_id: id}
       }),
       do: [id]

  defp block_file_ids(%ExGram.Model.RichBlockDocument{
         document: %ExGram.Model.Document{file_id: id}
       }),
       do: [id]

  defp block_file_ids(%{blocks: blocks}) when is_list(blocks),
    do: Enum.flat_map(blocks, &block_file_ids/1)

  defp block_file_ids(_block), do: []

  # Rich messages have no margins, so dividers keep the footer apart from the post.
  @spec separate([{atom(), struct()}], [{atom(), struct()}]) :: [{atom(), struct()}]
  defp separate(body, footer) do
    body = drop_trailing_divider(body)

    case {body, footer} do
      {[], footer} -> footer
      {body, []} -> body
      {body, footer} -> body ++ [{:other, divider()} | footer]
    end
  end

  @spec drop_trailing_divider([{atom(), struct()}]) :: [{atom(), struct()}]
  defp drop_trailing_divider(blocks) do
    case List.last(blocks) do
      {:other, %ExGram.Model.InputRichBlockDivider{}} -> List.delete_at(blocks, -1)
      _ -> blocks
    end
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

  @spec container(Lolek.Post.platform()) :: :collage | :slideshow
  defp container(platform) when platform in [:instagram, :tiktok], do: :slideshow
  defp container(_platform), do: :collage

  @spec section(atom(), Lolek.Post.t(), keyword()) :: [struct()]
  defp section(:header, post, _opts) do
    case header(post) do
      nil -> []
      header -> [paragraph(header), divider()]
    end
  end

  defp section(:text, post, _opts), do: post |> text(@max_text_chars) |> Enum.map(&paragraph/1)

  defp section(:reply_to, %Lolek.Post{reply_to: nil}, _opts), do: []

  defp section(:reply_to, %Lolek.Post{reply_to: %Lolek.Post{text: nil} = parent}, _opts) do
    case parent.author do
      %{handle: handle} when is_binary(handle) ->
        [paragraph(["↩️ Replying to ", link(parent.author.url || parent.url, "@" <> handle)])]

      _ ->
        []
    end
  end

  defp section(:reply_to, %Lolek.Post{reply_to: parent}, opts), do: linked_post(parent, opts)

  defp section(:quoted, %Lolek.Post{quoted: nil}, _opts), do: []
  defp section(:quoted, %Lolek.Post{quoted: quoted}, opts), do: linked_post(quoted, opts)

  defp section(:link_card, %Lolek.Post{link_card: nil}, _opts), do: []

  defp section(:link_card, %Lolek.Post{link_card: card}, _opts) do
    host = URI.parse(card.url).host

    blocks =
      [
        paragraph(bold(link(card.url, card.title || card.url))),
        card.description && paragraph(card.description),
        host && paragraph(host)
      ]
      |> Enum.reject(&is_nil/1)

    [%ExGram.Model.InputRichBlockBlockQuotation{type: "blockquote", blocks: blocks}]
  end

  defp section(:location, %Lolek.Post{extra: %{location: location}}, _opts),
    do: [paragraph("📍 " <> location)]

  defp section(:music, %Lolek.Post{extra: %{music: music}}, _opts),
    do: [paragraph("♫ " <> music)]

  defp section(:title, %Lolek.Post{title: title, text: text}, _opts) when is_binary(title) do
    if is_binary(text) and String.starts_with?(text, String.trim_trailing(title, ".")),
      do: [],
      else: [%ExGram.Model.InputRichBlockSectionHeading{type: "heading", text: title, size: 3}]
  end

  defp section(_name, _post, _opts), do: []

  # A quoted post or a parent post, shown as a quotation with its own header, text,
  # images, and source link.
  @spec linked_post(Lolek.Post.t(), keyword()) :: [struct()]
  defp linked_post(post, opts) do
    remote_media =
      if Keyword.get(opts, :remote_media, true), do: remote_media_blocks(post.media), else: []

    header = if header = header(post), do: [paragraph(header)], else: []
    text = post |> text(@max_linked_text_chars) |> Enum.map(&paragraph/1)

    case header ++ text ++ remote_media do
      [] ->
        []

      blocks ->
        source = if post.url, do: [paragraph(link(post.url, platform_name(post)))], else: []
        [%ExGram.Model.InputRichBlockBlockQuotation{type: "blockquote", blocks: blocks ++ source}]
    end
  end

  @spec header(Lolek.Post.t()) :: rich_text() | nil
  defp header(%Lolek.Post{author: nil}), do: nil

  defp header(%Lolek.Post{author: author}) do
    verified = if author.verified, do: [" ✓"], else: []

    case {author.name, author.handle} do
      {nil, handle} -> [bold(link(author.url, "@" <> handle)) | verified]
      {name, nil} -> [bold(link(author.url, name)) | verified]
      {name, handle} -> [bold(name)] ++ verified ++ [@separator, link(author.url, "@" <> handle)]
    end
  end

  # Returns one rich text for each paragraph. Line breaks in a paragraph stay as "\n".
  @spec text(Lolek.Post.t(), pos_integer()) :: [rich_text()]
  defp text(%Lolek.Post{text: nil}, _max_chars), do: []

  defp text(%Lolek.Post{text: text, facets: facets, platform: platform}, max_chars) do
    {text, facets} = truncate(text, facets, max_chars)

    text
    |> String.replace(["\r\n", "\r"], "\n")
    |> Lolek.RichPost.Linkify.segments(facets, platform)
    |> Enum.reduce([[]], fn
      {:text, value}, paragraphs ->
        [first | rest] = String.split(value, ~r/\n{2,}/)
        [current | done] = paragraphs
        Enum.reduce(rest, [[first | current] | done], &[[&1] | &2])

      {:link, label, url}, [current | done] ->
        [[link(url, label) | current] | done]
    end)
    |> Enum.map(&(&1 |> Enum.reverse() |> trim_parts()))
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
  end

  @spec trim_parts([rich_text()]) :: [rich_text()]
  defp trim_parts(parts) do
    parts
    |> trim_first(&String.trim_leading/1)
    |> Enum.reverse()
    |> trim_first(&String.trim_trailing/1)
    |> Enum.reverse()
  end

  @spec trim_first([rich_text()], (String.t() -> String.t())) :: [rich_text()]
  defp trim_first([first | rest], trim) when is_binary(first) do
    case trim.(first) do
      "" -> trim_first(rest, trim)
      trimmed -> [trimmed | rest]
    end
  end

  defp trim_first(parts, _trim), do: parts

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

  # The post details and the requester line are separate footers with a divider
  # between them.
  @spec footer(Lolek.Post.t(), keyword()) :: [struct()]
  defp footer(post, opts) do
    details =
      if Keyword.fetch!(opts, :details),
        do: footer_block([date_and_source(post), stats(post.stats)]),
        else: nil

    requester =
      case Keyword.get(opts, :requester) do
        requester when is_binary(requester) -> footer_block([requester])
        _ -> nil
      end

    [details, requester]
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(divider())
  end

  @spec footer_block([rich_text()]) :: struct() | nil
  defp footer_block(lines) do
    case Enum.reject(lines, &(&1 == [])) do
      [] ->
        nil

      lines ->
        %ExGram.Model.InputRichBlockFooter{type: "footer", text: Enum.intersperse(lines, "\n")}
    end
  end

  @spec date_and_source(Lolek.Post.t()) :: rich_text()
  defp date_and_source(post) do
    date =
      case post.published_at do
        %DateTime{} = datetime ->
          %ExGram.Model.RichTextDateTime{
            type: "date_time",
            text: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC"),
            unix_time: DateTime.to_unix(datetime),
            date_time_format: "Dt"
          }

        nil ->
          nil
      end

    source = if post.url, do: link(post.url, platform_name(post))

    [date, source]
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(@separator)
  end

  @spec stats(Lolek.Post.stats()) :: rich_text()
  defp stats(stats) do
    @stat_icons
    |> Enum.flat_map(fn {key, icon} ->
      case Map.get(stats, key) do
        count when is_integer(count) and count > 0 -> ["#{icon} #{compact_count(count)}"]
        _ -> []
      end
    end)
    |> Enum.intersperse(@separator)
    |> case do
      [] -> []
      parts -> Enum.join(parts)
    end
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

  # Returns the top-level blocks of the media: one block or a collage/slideshow for the
  # visual media, then one document block for each other file.
  @spec media_blocks([media()], :collage | :slideshow) :: [struct()]
  defp media_blocks(media, container) do
    {visual, documents} =
      media
      |> Enum.map(&media_entry/1)
      |> Enum.split_with(fn {kind, _block} -> kind != :document end)

    visual_block =
      case Enum.map(visual, &elem(&1, 1)) do
        [] -> []
        [single] -> [single]
        many -> [wrap(many, container)]
      end

    visual_block ++ Enum.map(documents, &elem(&1, 1))
  end

  @spec wrap([struct()], :collage | :slideshow) :: struct()
  defp wrap(blocks, :collage),
    do: %ExGram.Model.InputRichBlockCollage{type: "collage", blocks: blocks}

  defp wrap(blocks, :slideshow),
    do: %ExGram.Model.InputRichBlockSlideshow{type: "slideshow", blocks: blocks}

  @doc "Returns true when the file is shown as a photo, a video, or an animation."
  @spec visual_media?(String.t()) :: boolean()
  def visual_media?(ext) do
    ext in @gif_extensions or ext in @photo_extensions or
      Lolek.GalleryDownloader.video_file?("x#{ext}")
  end

  @spec media_entry(media()) :: {:visual | :document, struct()}
  defp media_entry(%{source: source, ext: ext} = item) do
    options = Map.get(item, :options, [])

    cond do
      ext in @gif_extensions ->
        {:visual,
         %ExGram.Model.InputRichBlockAnimation{
           type: "animation",
           animation: %ExGram.Model.InputMediaAnimation{type: "animation", media: source}
         }}

      Lolek.GalleryDownloader.video_file?("x#{ext}") ->
        {:visual,
         %ExGram.Model.InputRichBlockVideo{type: "video", video: video_input(source, options)}}

      ext in @photo_extensions ->
        {:visual, photo_block(source)}

      true ->
        {:document,
         %ExGram.Model.InputRichBlockDocument{
           type: "document",
           document: %ExGram.Model.InputMediaDocument{type: "document", media: source}
         }}
    end
  end

  @spec photo_block(term()) :: ExGram.Model.InputRichBlockPhoto.t()
  defp photo_block(source) do
    %ExGram.Model.InputRichBlockPhoto{
      type: "photo",
      photo: %ExGram.Model.InputMediaPhoto{type: "photo", media: source}
    }
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

  @spec remote_media_blocks([Lolek.Post.remote_media()]) :: [struct()]
  defp remote_media_blocks(media) do
    media
    |> Enum.filter(&(&1.type == :photo))
    |> Enum.take(@max_remote_media)
    |> Enum.map(&photo_block(&1.url))
    |> case do
      [] -> []
      [single] -> [single]
      many -> [wrap(many, :collage)]
    end
  end

  @spec paragraph(rich_text()) :: ExGram.Model.InputRichBlockParagraph.t()
  defp paragraph(text), do: %ExGram.Model.InputRichBlockParagraph{type: "paragraph", text: text}

  @spec divider() :: ExGram.Model.InputRichBlockDivider.t()
  defp divider, do: %ExGram.Model.InputRichBlockDivider{type: "divider"}

  @spec bold(rich_text()) :: ExGram.Model.RichTextBold.t()
  defp bold(text), do: %ExGram.Model.RichTextBold{type: "bold", text: text}

  @spec link(String.t() | nil, String.t()) :: rich_text()
  defp link(nil, label), do: label
  defp link(url, label), do: %ExGram.Model.RichTextUrl{type: "url", text: label, url: url}
end
