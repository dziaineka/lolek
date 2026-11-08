defmodule Lolek.Test.RichMarkup do
  @moduledoc """
  Renders rich message blocks as short HTML-like markup, so tests can compare layouts.
  """

  @doc "Renders a rich message or a list of blocks."
  def render(%ExGram.Model.InputRichMessage{blocks: blocks}), do: render(blocks)
  def render(blocks) when is_list(blocks), do: Enum.map_join(blocks, &block/1)

  defp block(%ExGram.Model.InputRichBlockParagraph{text: text}), do: "<p>#{text(text)}</p>"
  defp block(%ExGram.Model.InputRichBlockDivider{}), do: "<hr/>"
  defp block(%ExGram.Model.InputRichBlockFooter{text: text}), do: "<footer>#{text(text)}</footer>"

  defp block(%ExGram.Model.InputRichBlockSectionHeading{text: text, size: size}),
    do: "<h#{size}>#{text(text)}</h#{size}>"

  defp block(%ExGram.Model.InputRichBlockBlockQuotation{blocks: blocks}),
    do: "<blockquote>#{render(blocks)}</blockquote>"

  defp block(%ExGram.Model.InputRichBlockExpandableBlockQuotation{text: text}),
    do: "<blockquote expandable>#{text(text)}</blockquote>"

  defp block(%ExGram.Model.InputRichBlockCollage{blocks: blocks}),
    do: "<tg-collage>#{render(blocks)}</tg-collage>"

  defp block(%ExGram.Model.InputRichBlockSlideshow{blocks: blocks}),
    do: "<tg-slideshow>#{render(blocks)}</tg-slideshow>"

  defp block(%ExGram.Model.InputRichBlockPhoto{photo: %{media: media}}),
    do: ~s(<img src="#{source(media)}"/>)

  defp block(%ExGram.Model.InputRichBlockVideo{video: %{media: media}}),
    do: ~s(<video src="#{source(media)}"/>)

  defp block(%ExGram.Model.InputRichBlockAnimation{animation: %{media: media}}),
    do: ~s(<animation src="#{source(media)}"/>)

  defp block(%ExGram.Model.InputRichBlockDocument{document: %{media: media}}),
    do: ~s(<tg-document src="#{source(media)}"/>)

  defp text(text) when is_binary(text), do: String.replace(text, "\n", "<br>")
  defp text(parts) when is_list(parts), do: Enum.map_join(parts, &text/1)
  defp text(%ExGram.Model.RichTextBold{text: text}), do: "<b>#{text(text)}</b>"

  defp text(%ExGram.Model.RichTextUrl{text: text, url: url}),
    do: ~s(<a href="#{url}">#{text(text)}</a>)

  defp text(%ExGram.Model.RichTextDateTime{} = date),
    do:
      ~s(<tg-time unix="#{date.unix_time}" format="#{date.date_time_format}">#{text(date.text)}</tg-time>)

  defp source(media) when is_binary(media), do: media
  defp source({:file_content, _stream, name}), do: "upload:" <> name
  defp source(other), do: inspect(other)
end
