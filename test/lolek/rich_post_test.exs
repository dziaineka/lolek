defmodule Lolek.RichPostTest do
  use ExUnit.Case, async: true

  describe "media blocks" do
    test "sends a single video as a video block with its size" do
      rich_message =
        Lolek.RichPost.build([{:video, "VIDEO", width: 640, height: 360, duration: 7}], [])

      assert [
               %ExGram.Model.InputRichBlockVideo{
                 type: "video",
                 video: %ExGram.Model.InputMediaVideo{
                   type: "video",
                   media: "VIDEO",
                   width: 640,
                   height: 360,
                   duration: 7,
                   supports_streaming: true
                 }
               }
             ] = rich_message.blocks
    end

    test "sends a single photo and a single GIF as their own blocks" do
      assert [%ExGram.Model.InputRichBlockPhoto{photo: %{media: "PHOTO"}}] =
               Lolek.RichPost.build([{:photo, "PHOTO", []}], []).blocks

      assert [%ExGram.Model.InputRichBlockAnimation{animation: %{media: "GIF"}}] =
               Lolek.RichPost.build([{:animation, "GIF", []}], []).blocks
    end

    test "puts a gallery into one collage" do
      media = Enum.map(1..12, &{:photo, "PHOTO_#{&1}", []})

      assert [%ExGram.Model.InputRichBlockCollage{type: "collage", blocks: blocks}] =
               Lolek.RichPost.build(media, []).blocks

      assert Enum.map(blocks, & &1.photo.media) == Enum.map(1..12, &"PHOTO_#{&1}")
    end

    test "keeps GIFs after the collage" do
      media =
        Lolek.RichPost.arrange([
          {:photo, "P1", []},
          {:animation, "GIF", []},
          {:video, "V1", []},
          {:photo, "P2", []}
        ])

      assert Enum.map(media, &elem(&1, 1)) == ["P1", "V1", "P2", "GIF"]

      assert [
               %ExGram.Model.InputRichBlockCollage{blocks: [_, _, _]},
               %ExGram.Model.InputRichBlockAnimation{animation: %{media: "GIF"}}
             ] = Lolek.RichPost.build(media, []).blocks
    end

    test "does not build a collage around one photo next to GIFs" do
      assert [%ExGram.Model.InputRichBlockPhoto{}, %ExGram.Model.InputRichBlockAnimation{}] =
               Lolek.RichPost.build([{:photo, "P", []}, {:animation, "G", []}], []).blocks
    end
  end

  describe "description" do
    test "shows a short description as a paragraph" do
      assert [_photo, %ExGram.Model.InputRichBlockParagraph{text: "Short caption"}] =
               build_with_description("  Short caption \n\n")
    end

    test "hides lines after the third one" do
      description = Enum.map_join(1..20, "\n", &"line #{&1}")

      assert [_photo, p1, p2, p3, %ExGram.Model.InputRichBlockDetails{} = details] =
               build_with_description(description)

      assert Enum.map([p1, p2, p3], & &1.text) == ["line 1", "line 2", "line 3"]
      assert details.summary == "Show more"
      assert details.is_open == nil
      assert Enum.map(details.blocks, & &1.text) == Enum.map(4..20, &"line #{&1}")
    end

    test "cuts a long first line at a word boundary" do
      words = Enum.map_join(1..200, " ", &"w#{&1}")

      assert [
               _photo,
               %{text: visible},
               %ExGram.Model.InputRichBlockDetails{blocks: [%{text: hidden}]}
             ] =
               build_with_description(words)

      assert String.length(visible) <= 300
      assert String.ends_with?(visible, "…")
      assert String.starts_with?(hidden, "…")

      assert String.trim_trailing(visible, "…") <> " " <> String.trim_leading(hidden, "…") ==
               words
    end

    test "cuts a short title before a long link mid-word instead of leaving a scrap" do
      link = "https://example.com/" <> String.duplicate("a", 400)

      assert [
               _photo,
               %{text: visible},
               %ExGram.Model.InputRichBlockDetails{blocks: [%{text: hidden}]}
             ] =
               build_with_description("Title " <> link)

      assert String.length(visible) == 300
      assert String.starts_with?(visible, "Title https://example.com/")

      assert String.trim_trailing(visible, "…") <> String.trim_leading(hidden, "…") ==
               "Title " <> link
    end

    test "hides a line that would be cut to a scrap" do
      description = String.duplicate("a", 290) <> "\nsecond line that does not fit"

      assert [
               _photo,
               %{text: first},
               %ExGram.Model.InputRichBlockDetails{blocks: [%{text: second}]}
             ] =
               build_with_description(description)

      assert first == String.duplicate("a", 290)
      assert second == "second line that does not fit"
    end

    test "keeps descriptions within rich message limits" do
      description = Enum.map_join(1..1000, "\n", &"line #{&1}")

      assert [_photo, _p1, _p2, _p3, %ExGram.Model.InputRichBlockDetails{blocks: hidden}] =
               build_with_description(description)

      assert length(hidden) == 400
      assert List.last(hidden).text == "line 403…"

      [_photo | blocks] = build_with_description(String.duplicate("😀", 40_000))
      text = blocks |> collect_text() |> Enum.join()
      assert length(String.codepoints(text)) <= 30_000 + 2
    end

    test "adds nothing without a description" do
      assert [%ExGram.Model.InputRichBlockPhoto{}] = build_with_description(nil)
      assert [%ExGram.Model.InputRichBlockPhoto{}] = build_with_description("\n  \n")
    end
  end

  describe "footer" do
    test "mentions the requester" do
      user = %ExGram.Model.User{id: 7, is_bot: false, first_name: "Ann"}
      mention = Lolek.Requester.mention(user)

      assert [_photo, %ExGram.Model.InputRichBlockFooter{text: ["requested by ", ^mention]}] =
               Lolek.RichPost.build([{:photo, "P", []}], mention: mention).blocks
    end

    test "has no footer without a mention" do
      assert [_photo] = Lolek.RichPost.build([{:photo, "P", []}], mention: nil).blocks
    end
  end

  describe "file ids" do
    test "reads file ids of a sent rich message in block order" do
      response = %{
        message_id: 1,
        date: 0,
        chat: %{id: 1, type: "private"},
        rich_message: %{
          blocks: [
            %{
              type: "collage",
              blocks: [
                %{
                  type: "photo",
                  photo: [
                    %{file_id: "small", file_unique_id: "s", width: 1, height: 1},
                    %{file_id: "PHOTO", file_unique_id: "p", width: 2, height: 2}
                  ]
                },
                %{type: "video", video: video("VIDEO")}
              ]
            },
            %{type: "animation", animation: video("GIF")},
            %{type: "paragraph", text: "caption"}
          ]
        }
      }

      {:ok, message} = ExGram.Cast.cast(response, ExGram.Model.Message)

      assert Lolek.RichPost.file_ids(message) == ["PHOTO", "VIDEO", "GIF"]
    end

    test "returns nothing for other messages" do
      assert Lolek.RichPost.file_ids(%ExGram.Model.Message{}) == []
    end
  end

  defp build_with_description(description) do
    Lolek.RichPost.build([{:photo, "P", []}], description: description).blocks
  end

  defp collect_text(blocks) do
    Enum.flat_map(blocks, fn
      %ExGram.Model.InputRichBlockDetails{blocks: nested} -> collect_text(nested)
      %{text: text} -> [text]
    end)
  end

  defp video(file_id) do
    %{file_id: file_id, file_unique_id: file_id, width: 1, height: 1, duration: 1}
  end
end
