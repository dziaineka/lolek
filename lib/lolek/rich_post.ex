defmodule Lolek.RichPost do
  @moduledoc """
  Builds the rich message blocks of a post and reads the sent file ids back.
  """

  @visible_lines 3
  @visible_chars 300
  @min_visible_cut 40
  # Rich messages allow 32768 characters and 500 blocks in total; the rest of
  # the budget goes to the footer and to up to 50 media blocks.
  @max_description_chars 30_000
  @max_hidden_paragraphs 400
  @ellipsis "…"
  @hidden_summary "Show more"

  @type media_kind :: :photo | :video | :animation
  @type media :: {media_kind(), term(), keyword()}

  @doc """
  Orders media the way `build/2` places them: photos and videos first, then
  GIFs. Takes any tuples whose first element is the media kind, so callers can
  order their own items the same way.
  """
  @spec arrange([tuple()]) :: [tuple()]
  def arrange(media) do
    {visual, animations} = split_animations(media)
    visual ++ animations
  end

  @doc """
  Builds the post from arranged media, an optional description and an optional mention.
  """
  @spec build([media()], keyword()) :: ExGram.Model.InputRichMessage.t()
  def build(media, options) do
    %ExGram.Model.InputRichMessage{
      blocks:
        media_blocks(media) ++
          description_blocks(Keyword.get(options, :description)) ++
          footer_blocks(Keyword.get(options, :mention))
    }
  end

  @doc """
  Returns the file ids of the media in a sent rich message, in block order.
  """
  @spec file_ids(term()) :: [String.t()]
  def file_ids(%ExGram.Model.Message{rich_message: %ExGram.Model.RichMessage{blocks: blocks}})
      when is_list(blocks) do
    Enum.flat_map(blocks, &block_file_ids/1)
  end

  def file_ids(_message), do: []

  @spec block_file_ids(term()) :: [String.t()]
  defp block_file_ids(%ExGram.Model.RichBlockCollage{blocks: blocks}) when is_list(blocks),
    do: Enum.flat_map(blocks, &block_file_ids/1)

  defp block_file_ids(%ExGram.Model.RichBlockPhoto{photo: [_ | _] = sizes}),
    do: [List.last(sizes).file_id]

  defp block_file_ids(%ExGram.Model.RichBlockVideo{video: %ExGram.Model.Video{file_id: id}}),
    do: [id]

  defp block_file_ids(%ExGram.Model.RichBlockAnimation{
         animation: %ExGram.Model.Animation{file_id: id}
       }),
       do: [id]

  defp block_file_ids(_block), do: []

  @spec split_animations([tuple()]) :: {[tuple()], [tuple()]}
  defp split_animations(media), do: Enum.split_with(media, &(elem(&1, 0) != :animation))

  @spec media_blocks([media()]) :: [struct()]
  defp media_blocks(media) do
    {visual, animations} = split_animations(media)
    visual_blocks(visual) ++ Enum.map(animations, &media_block/1)
  end

  # A collage needs at least two items; GIFs stay outside it because Telegram
  # only documents photos and videos as collage elements.
  @spec visual_blocks([media()]) :: [struct()]
  defp visual_blocks([]), do: []
  defp visual_blocks([single]), do: [media_block(single)]

  defp visual_blocks(visual) do
    [
      %ExGram.Model.InputRichBlockCollage{
        type: "collage",
        blocks: Enum.map(visual, &media_block/1)
      }
    ]
  end

  @spec media_block(media()) :: struct()
  defp media_block({:photo, source, _attrs}) do
    %ExGram.Model.InputRichBlockPhoto{
      type: "photo",
      photo: %ExGram.Model.InputMediaPhoto{type: "photo", media: source}
    }
  end

  defp media_block({:video, source, attrs}) do
    %ExGram.Model.InputRichBlockVideo{
      type: "video",
      video: %ExGram.Model.InputMediaVideo{
        type: "video",
        media: source,
        width: Keyword.get(attrs, :width),
        height: Keyword.get(attrs, :height),
        duration: Keyword.get(attrs, :duration),
        supports_streaming: true
      }
    }
  end

  defp media_block({:animation, source, _attrs}) do
    %ExGram.Model.InputRichBlockAnimation{
      type: "animation",
      animation: %ExGram.Model.InputMediaAnimation{type: "animation", media: source}
    }
  end

  @spec description_blocks(String.t() | nil) :: [struct()]
  defp description_blocks(description) when is_binary(description) do
    lines =
      description
      |> truncate(@max_description_chars)
      |> String.split(~r/\R/u)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {visible, hidden} = split_visible(lines, [], @visible_lines, @visible_chars)
    Enum.map(visible, &paragraph/1) ++ hidden_blocks(hidden)
  end

  defp description_blocks(_description), do: []

  @spec split_visible([String.t()], [String.t()], non_neg_integer(), non_neg_integer()) ::
          {[String.t()], [String.t()]}
  defp split_visible([], visible, _lines_left, _chars_left), do: {Enum.reverse(visible), []}
  defp split_visible(rest, visible, 0, _chars_left), do: {Enum.reverse(visible), rest}

  defp split_visible([line | rest], visible, lines_left, chars_left) do
    length = String.length(line)

    if length <= chars_left do
      split_visible(rest, [line | visible], lines_left - 1, chars_left - length)
    else
      case cut_at_word(line, chars_left - String.length(@ellipsis)) do
        {"", _tail} ->
          {Enum.reverse(visible), [line | rest]}

        {head, tail} ->
          {Enum.reverse([head <> @ellipsis | visible]), [@ellipsis <> tail | rest]}
      end
    end
  end

  @spec cut_at_word(String.t(), integer()) :: {String.t(), String.t()}
  defp cut_at_word(_line, max_chars) when max_chars < @min_visible_cut, do: {"", ""}

  defp cut_at_word(line, max_chars) do
    prefix = String.slice(line, 0, max_chars)

    word_head =
      cond do
        String.match?(String.at(line, max_chars) || "", ~r/^\s$/u) -> prefix
        match = Regex.run(~r/^(.*\S)\s/su, prefix, capture: :all_but_first) -> hd(match)
        true -> prefix
      end

    # A word boundary right after a short first word (a title before a long
    # link) would leave a scrap visible, so such a line is cut mid-word.
    head =
      if String.length(word_head) < @min_visible_cut,
        do: String.trim_trailing(prefix),
        else: String.trim_trailing(word_head)

    tail =
      line
      |> String.slice(String.length(head)..-1//1)
      |> String.trim_leading()

    {head, tail}
  end

  @spec hidden_blocks([String.t()]) :: [struct()]
  defp hidden_blocks([]), do: []

  defp hidden_blocks(lines) do
    [
      %ExGram.Model.InputRichBlockDetails{
        type: "details",
        summary: @hidden_summary,
        blocks: lines |> limit_paragraphs() |> Enum.map(&paragraph/1)
      }
    ]
  end

  @spec limit_paragraphs([String.t()]) :: [String.t()]
  defp limit_paragraphs(lines) when length(lines) <= @max_hidden_paragraphs, do: lines

  defp limit_paragraphs(lines) do
    {kept, _dropped} = Enum.split(lines, @max_hidden_paragraphs)
    List.update_at(kept, -1, &(&1 <> @ellipsis))
  end

  # Telegram counts the limit in characters, not graphemes: one emoji can be
  # several code points.
  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(text, max_chars) do
    codepoints = String.codepoints(text)

    if length(codepoints) <= max_chars do
      text
    else
      codepoints |> Enum.take(max_chars - 1) |> Enum.join() |> Kernel.<>(@ellipsis)
    end
  end

  @spec paragraph(String.t()) :: ExGram.Model.InputRichBlockParagraph.t()
  defp paragraph(text), do: %ExGram.Model.InputRichBlockParagraph{type: "paragraph", text: text}

  @spec footer_blocks(term()) :: [ExGram.Model.InputRichBlockFooter.t()]
  defp footer_blocks(nil), do: []

  defp footer_blocks(mention) do
    [%ExGram.Model.InputRichBlockFooter{type: "footer", text: ["requested by ", mention]}]
  end
end
