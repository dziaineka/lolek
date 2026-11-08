defmodule Lolek.SendFileTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc """
    Records each call and answers with the result of the configured responder.
    """

    @behaviour Lolek.Telegram

    @impl true
    def send_rich_message(chat_id, rich_message, options),
      do: respond({:send_rich_message, chat_id, rich_message, options})

    @impl true
    def edit_message_text(chat_id, message_id, options),
      do: respond({:edit_message_text, chat_id, message_id, options})

    @impl true
    def set_message_reaction(chat_id, message_id, options),
      do: respond({:set_message_reaction, chat_id, message_id, options})

    defp respond(call) do
      parent = Application.get_env(:lolek, :telegram_test_parent)

      if parent do
        send(parent, call)
        send(parent, {:local_files_exist, local_files_exist(call)})
      end

      counter = Application.fetch_env!(:lolek, :telegram_test_attempts)
      attempt = :atomics.add_get(counter, 1, 1)
      Application.fetch_env!(:lolek, :telegram_test_responder).(call, attempt)
    end

    defp local_files_exist({:send_rich_message, _chat_id, rich_message, _options}) do
      rich_message
      |> Lolek.SendFileTest.input_media()
      |> Enum.map(fn
        %{media: "file://" <> encoded_path} -> encoded_path |> URI.decode() |> File.exists?()
        _ -> :not_local
      end)
    end

    defp local_files_exist(_call), do: []
  end

  defmodule RaisingTelegramClient do
    @moduledoc false

    @behaviour Lolek.Telegram

    @impl true
    def send_rich_message(_chat_id, _rich_message, _options),
      do: raise(Application.fetch_env!(:lolek, :telegram_test_error))

    @impl true
    def edit_message_text(_chat_id, _message_id, _options),
      do: raise(Application.fetch_env!(:lolek, :telegram_test_error))

    @impl true
    def set_message_reaction(_chat_id, _message_id, _options),
      do: raise(Application.fetch_env!(:lolek, :telegram_test_error))
  end

  setup do
    # Video uploads read the video size with ffprobe.
    {:ok, _apps} = Application.ensure_all_started(:erlexec)

    keys = [
      :telegram_client,
      :telegram_test_responder,
      :telegram_test_attempts,
      :telegram_test_error,
      :telegram_test_parent,
      :telegram_local_file_uploads,
      :post_source_caption,
      :post_requester_caption,
      :max_gallery_media
    ]

    saved = Map.new(keys, &{&1, Application.fetch_env(:lolek, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)
    end)

    Application.put_env(:lolek, :telegram_client, TelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())
    Application.put_env(:lolek, :telegram_test_attempts, :atomics.new(1, []))
    Application.put_env(:lolek, :post_source_caption, false)
    Application.put_env(:lolek, :post_requester_caption, false)
    :ok
  end

  describe "errors and retries" do
    test "returns an error when Telegram rejects the message" do
      respond_with(fn _call, _attempt -> {:error, bad_request()} end)

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_rich_message, 123, _rich_message, _options}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "does not start a Telegram request after the processing deadline" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([video_block("x")])} end)
      test_pid = self()

      assert {:error, :processing_deadline_exceeded} =
               Lolek.ProcessingDeadline.run(
                 fn ->
                   # Model a command being cooperatively cancelled by the deadline. This lets
                   # the worker unwind far enough to attempt the upload after its deadline.
                   Lolek.ProcessingDeadline.with_command(0, fn ->
                     cancel_message = Lolek.ProcessingDeadline.cancellation_message()
                     send(test_pid, :waiting_for_deadline)

                     receive do
                       ^cancel_message -> :ok
                     end
                   end)

                   result = Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
                   send(test_pid, {:send_after_deadline, result})
                 end,
                 25
               )

      assert_receive :waiting_for_deadline
      assert_receive {:send_after_deadline, {:error, :processing_deadline_exceeded}}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "waits out a flood limit and sends the message on the retry" do
      flood_then_ok(retry_after: 0, failures: 1)

      assert {:ok, {:ready_media, [{"file-id", ".mp4"}]}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_rich_message, 123, _, _}
      assert_receive {:send_rich_message, 123, _, _}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "gives up on a flood limit that repeats" do
      flood_then_ok(retry_after: 0, failures: 2)

      assert {:error, {:telegram_api, %ExGram.Error{code: 429}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_rich_message, 123, _, _}
      assert_receive {:send_rich_message, 123, _, _}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "does not wait for a flood limit longer than the processing deadline" do
      flood_then_ok(retry_after: 59, failures: 1)
      test_pid = self()

      Lolek.ProcessingDeadline.run(
        fn ->
          result = Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
          send(test_pid, {:flood_result, result})
        end,
        200
      )

      assert_receive {:flood_result, {:error, {:telegram_api, %ExGram.Error{code: 429}}}}
      assert_receive {:send_rich_message, 123, _, _}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "a flood limit without the retry hint is not waited out" do
      flood_then_ok(retry_after: nil, failures: 1)

      assert {:error, {:telegram_api, %ExGram.Error{code: 429}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_rich_message, 123, _, _}
      refute_receive {:send_rich_message, _, _, _}
    end

    test "returns an error when Telegram raises while sending" do
      Application.put_env(:lolek, :telegram_client, RaisingTelegramClient)

      Application.put_env(:lolek, :telegram_test_error, %ExGram.Error{
        code: 500,
        message: "Internal Error"
      })

      assert {:error, {:telegram_api, %ExGram.Error{code: 500, message: "Internal Error"}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
    end

    test "returns an error for an unexpected Telegram response" do
      respond_with(fn _call, _attempt -> {:ok, true} end)

      assert {:error, {:unexpected_telegram_response, true}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
    end

    test "returns an error when there are no media files" do
      assert {:error, :no_usable_media_files} =
               Lolek.send_file(123, {:prepared_media, "/tmp", []})
    end

    test "sends the post again without linked media when Telegram rejects it" do
      respond_with(fn
        _call, 1 ->
          {:error, bad_request()}

        _call, _attempt ->
          {:ok, rich_response([%ExGram.Model.RichBlockParagraph{}, photo_block("photo-id")])}
      end)

      Application.put_env(:lolek, :post_source_caption, true)
      file_path = tmp_file("gallery-1.jpg", "media")

      quoted = %Lolek.Post{
        platform: :bluesky,
        text: "quoted",
        media: [%{type: :photo, url: "https://cdn.example/quoted.jpg"}]
      }

      post = %Lolek.Post{platform: :bluesky, text: "main", quoted: quoted}

      assert {:ok, {:sent_media, _, [{".jpg", "photo-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 post: post
               )

      assert_receive {:send_rich_message, 123, first, _}
      assert markup(first) =~ ~s(<img src="https://cdn.example/quoted.jpg"/>)
      assert_receive {:send_rich_message, 123, second, _}
      second = markup(second)
      refute second =~ "https://cdn.example/quoted.jpg"
      assert second =~ "quoted"
    end

    test "does not send the post again when it has no linked media" do
      respond_with(fn _call, _attempt -> {:error, bad_request()} end)
      Application.put_env(:lolek, :post_source_caption, true)

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".jpg"}]},
                 post: %Lolek.Post{text: "main"}
               )

      assert_receive {:send_rich_message, _, _, _}
      refute_receive {:send_rich_message, _, _, _}
    end
  end

  describe "media" do
    test "uploads one video as a rich message and returns its file_id" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([video_block("video-id")])} end)
      file_path = tmp_file("downloaded.mp4", "media")

      assert {:ok, {:sent_media, _, [{".mp4", "video-id"}]}} =
               Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]},
                 message_thread_id: 456
               )

      assert_receive {:send_rich_message, 123,
                      %ExGram.Model.InputRichMessage{skip_entity_detection: true} = rich_message,
                      options}

      assert markup(rich_message) == ~s(<video src="upload:downloaded.mp4"/>)

      assert [
               %ExGram.Model.InputMediaVideo{
                 type: "video",
                 supports_streaming: true,
                 media: {:file_content, %File.Stream{} = stream, "downloaded.mp4"}
               }
             ] = input_media(rich_message)

      assert stream.path == file_path
      assert stream.line_or_bytes == 64 * 1024
      assert options[:message_thread_id] == 456
      assert options[:disable_notification] == true
    end

    test "sends a gallery as a collage and keeps the order of the file_ids" do
      respond_with(fn _call, _attempt ->
        {:ok,
         rich_response([
           %ExGram.Model.RichBlockCollage{
             type: "collage",
             blocks: [photo_block("p1"), video_block("v2"), photo_block("p3")]
           }
         ])}
      end)

      files = [
        tmp_file("gallery-1.jpg", "media"),
        tmp_file("gallery-2.mp4", "media"),
        tmp_file("gallery-3.png", "media")
      ]

      assert {:ok, {:sent_media, "/tmp", [{".jpg", "p1"}, {".mp4", "v2"}, {".png", "p3"}]}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert_receive {:send_rich_message, 123, rich_message, _}

      assert markup(rich_message) ==
               ~s(<tg-collage><img src="upload:gallery-1.jpg"/><video src="upload:gallery-2.mp4"/>) <>
                 ~s(<img src="upload:gallery-3.png"/></tg-collage>)
    end

    test "sends Instagram galleries as a slideshow" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.jpg", "media")

      Lolek.send_file(123, {:prepared_media, "/tmp", files},
        post: %Lolek.Post{platform: :instagram}
      )

      assert_receive {:send_rich_message, 123, rich_message, _}
      assert markup(rich_message) =~ "<tg-slideshow>"
    end

    test "does not cache file_ids that do not match the uploaded files" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([photo_block("p1")])} end)
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.jpg", "media")
      file_state = {:prepared_media, "/tmp", files}

      assert {:ok, ^file_state} = Lolek.send_file(123, file_state)
    end

    test "limits a gallery to the configured maximum number of media files" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :max_gallery_media, 2)
      files = for index <- 1..3, do: tmp_file("gallery-#{index}.jpg", "media")

      Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert_receive {:send_rich_message, 123, rich_message, _}
      assert length(input_media(rich_message)) == 2
    end

    test "sends cached media by file_id and applies the gallery limit" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :max_gallery_media, 2)
      entries = [{"id-1", ".jpg"}, {"id-2", ".gif"}, {"id-3", ".jpg"}]

      assert {:ok, {:ready_media, [{"id-1", ".jpg"}, {"id-2", ".gif"}]}} =
               Lolek.send_file(123, {:ready_media, entries})

      assert_receive {:send_rich_message, 123, rich_message, _}

      assert markup(rich_message) ==
               ~s(<tg-collage><img src="id-1"/><animation src="id-2"/></tg-collage>)

      assert [
               %ExGram.Model.InputMediaPhoto{media: "id-1"},
               %ExGram.Model.InputMediaAnimation{media: "id-2"}
             ] = input_media(rich_message)
    end

    test "sends other files as documents after the visual media and keeps their file_ids" do
      respond_with(fn _call, _attempt ->
        {:ok,
         rich_response([
           photo_block("new-photo"),
           %ExGram.Model.RichBlockDocument{document: %ExGram.Model.Document{file_id: "new-doc"}}
         ])}
      end)

      files = [tmp_file("file.txt", "doc"), tmp_file("photo.jpg", "photo")]

      assert {:ok, {:sent_media, "/tmp", [{".jpg", "new-photo"}, {".txt", "new-doc"}]}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert_receive {:send_rich_message, 123, rich_message, _}

      assert markup(rich_message) ==
               ~s(<img src="upload:photo.jpg"/><tg-document src="upload:file.txt"/>)
    end
  end

  describe "uploads" do
    test "sends local file uris and cleans upload aliases" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :telegram_local_file_uploads, true)
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.jpg", "media")

      Lolek.send_file(123, {:prepared_media, "/tmp", files}, post: post_titled("Gallery title"))

      assert_receive {:send_rich_message, 123, rich_message, []}
      assert Enum.all?(input_media(rich_message), &String.starts_with?(&1.media, "file://"))
      assert_receive {:local_files_exist, [true, true]}

      for file <- files do
        assert [] = Path.wildcard(Path.join(Path.dirname(file), ".telegram-upload-*"))
      end
    end

    test "sends the file path as a local file uri when the name does not change" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :telegram_local_file_uploads, true)
      file_path = tmp_file("downloaded with spaces.mp4", "media")

      Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

      assert_receive {:send_rich_message, 123, rich_message, _}
      [media] = input_media(rich_message)
      assert "file://" <> encoded_path = media.media
      assert encoded_path == String.replace(file_path, " ", "%20")
    end

    test "cleans prepared uploads when a later item cannot be prepared" do
      Application.put_env(:lolek, :telegram_local_file_uploads, true)
      file_path = tmp_file("gallery-1.jpg", "media")
      missing_path = Path.join(Path.dirname(file_path), "missing.jpg")

      assert {:error, {:local_upload_alias, :enoent}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", [file_path, missing_path]},
                 post: post_titled("Gallery title")
               )

      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
      refute_receive {:send_rich_message, _, _, _}
    end

    test "uses sanitized post titles as upload file names" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      file_path = tmp_file("compressed.mp4", "media")

      Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]},
        post: post_titled("A / Video: https://example.com/watch Title?")
      )

      assert_receive {:send_rich_message, 123, rich_message, _}
      [media] = input_media(rich_message)
      assert {:file_content, %File.Stream{}, "A Video Title.mp4"} = media.media
    end

    test "uses post titles as local upload file names" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :telegram_local_file_uploads, true)
      file_path = tmp_file("compressed.mp4", "media")

      Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]},
        post: post_titled("A / Video: https://example.com/watch Title?")
      )

      assert_receive {:send_rich_message, 123, rich_message, _}
      [media] = input_media(rich_message)
      assert "file://" <> encoded_path = media.media
      assert encoded_path |> URI.decode() |> Path.basename() == "A Video Title.mp4"
      assert File.exists?(file_path)
      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
    end

    for {name, title_char, measure} <- [
          {"conservative and filesystem byte limits", "€", :raw},
          {"byte limits after Unicode decomposition", "Ǖ", :nfd}
        ] do
      test "keeps local upload file names within #{name}" do
        respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
        Application.put_env(:lolek, :telegram_local_file_uploads, true)
        file_path = tmp_file("compressed.mp4", "media")
        max_bytes = min(180, name_max(Path.dirname(file_path)))
        title = String.duplicate(unquote(title_char), 100)
        assert byte_size(title <> ".mp4") > max_bytes

        Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]},
          post: post_titled(title)
        )

        assert_receive {:send_rich_message, 123, rich_message, _}
        [media] = input_media(rich_message)

        "file://" <> encoded_path = media.media
        upload_file_name = encoded_path |> URI.decode() |> Path.basename()

        measured =
          if unquote(measure) == :nfd,
            do: String.normalize(upload_file_name, :nfd),
            else: upload_file_name

        assert byte_size(measured) <= max_bytes
        assert String.valid?(upload_file_name)
        assert String.ends_with?(upload_file_name, ".mp4")
        assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
      end
    end
  end

  describe "post details and requester line" do
    test "sends text posts with the post text and the requester line" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :post_requester_caption, true)

      context = [
        requester_name: "alice",
        started_at: System.monotonic_time(),
        message_thread_id: 456
      ]

      file_state = {:text_post, "/tmp/cache", "post text"}

      assert {:ok, ^file_state} = Lolek.send_file(123, file_state, context)

      assert_receive {:send_rich_message, 123, rich_message, options}
      assert input_media(rich_message) == []
      html = markup(rich_message)

      assert html =~
               ~r{^<p>post text</p><hr/><footer>alice requested, processed in \d+\.\ds</footer>$}

      assert options[:message_thread_id] == 456
    end

    test "uses the post metadata of text posts" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)

      post = %Lolek.Post{
        platform: :twitter,
        author: Lolek.Post.author("Jack", "jack", "https://x.com/jack"),
        text: "just setting up my twttr"
      }

      Lolek.send_file(123, {:text_post, "/tmp/cache", "ignored"}, post: post)

      assert_receive {:send_rich_message, 123, rich_message, _}
      html = markup(rich_message)
      assert html =~ ~s(<b>Jack</b> · <a href="https://x.com/jack">@jack</a>)
      assert html =~ "<p>just setting up my twttr</p>"
    end

    test "returns Telegram errors for text posts" do
      respond_with(fn _call, _attempt -> {:error, bad_request()} end)

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:text_post, "/tmp/cache", "post text"})
    end

    test "does not show the post details when disabled" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)

      Lolek.send_file(123, {:ready_media, [{"id", ".jpg"}]},
        post: %Lolek.Post{text: "secret", author: Lolek.Post.author("Name", nil, nil)}
      )

      assert_receive {:send_rich_message, 123, rich_message, _}
      html = markup(rich_message)
      assert html == ~s(<img src="id"/>)
    end

    test "shows the post details when enabled" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([])} end)
      Application.put_env(:lolek, :post_source_caption, true)

      Lolek.send_file(123, {:ready_media, [{"id", ".jpg"}]},
        post: %Lolek.Post{text: "shown", author: Lolek.Post.author("Name", nil, nil)}
      )

      assert_receive {:send_rich_message, 123, rich_message, _}
      html = markup(rich_message)
      assert html =~ "<p><b>Name</b></p>"
      assert html =~ "<p>shown</p>"
    end

    test "updates the processing time with the new file_ids after the upload" do
      respond_with(fn
        {:send_rich_message, _, _, _}, _attempt -> {:ok, rich_response([video_block("new-id")])}
        {:edit_message_text, _, _, _}, _attempt -> {:ok, rich_response([video_block("new-id")])}
      end)

      Application.put_env(:lolek, :post_requester_caption, true)
      file_path = tmp_file("downloaded.mp4", "media")
      context = [requester_name: "alice", started_at: System.monotonic_time()]

      assert {:ok, {:sent_media, _, [{".mp4", "new-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_rich_message, 123, _, _}
      assert_receive {:edit_message_text, 123, 77, [rich_message: rich_message]}
      assert [%ExGram.Model.InputMediaVideo{media: "new-id"}] = input_media(rich_message)
      assert markup(rich_message) =~ ~r{<footer>alice requested, processed in \d+\.\ds</footer>}
    end

    test "does not edit the message when the requester line is off" do
      respond_with(fn _call, _attempt -> {:ok, rich_response([video_block("new-id")])} end)
      file_path = tmp_file("downloaded.mp4", "media")

      Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

      assert_receive {:send_rich_message, 123, _, _}
      refute_receive {:edit_message_text, _, _, _}
    end

    test "keeps the result when the edit fails" do
      respond_with(fn
        {:send_rich_message, _, _, _}, _attempt -> {:ok, rich_response([video_block("new-id")])}
        {:edit_message_text, _, _, _}, _attempt -> {:error, bad_request()}
      end)

      Application.put_env(:lolek, :post_requester_caption, true)
      context = [requester_name: "alice", started_at: System.monotonic_time()]

      assert {:ok, {:ready_media, [{"new-id", ".mp4"}]}} =
               Lolek.send_file(123, {:ready_media, [{"new-id", ".mp4"}]}, context)

      assert_receive {:edit_message_text, 123, 77, _}
    end
  end

  defp markup(rich_message), do: Lolek.Test.RichMarkup.render(rich_message)

  @doc false
  # The uploaded and cached media of a rich message, in block order.
  def input_media(%ExGram.Model.InputRichMessage{blocks: blocks}),
    do: Enum.flat_map(blocks, &block_media/1)

  defp block_media(%{photo: %{} = media}), do: [media]
  defp block_media(%{video: %{} = media}), do: [media]
  defp block_media(%{animation: %{} = media}), do: [media]
  defp block_media(%{document: %{} = media}), do: [media]

  defp block_media(%{blocks: blocks}) when is_list(blocks),
    do: Enum.flat_map(blocks, &block_media/1)

  defp block_media(_block), do: []

  defp respond_with(fun), do: Application.put_env(:lolek, :telegram_test_responder, fun)

  # Answers with a flood limit for the first `failures` attempts. `retry_after` of nil
  # models a flood limit that Telegram sent without the hint.
  defp flood_then_ok(opts) do
    parameters =
      case Keyword.fetch!(opts, :retry_after) do
        nil -> []
        seconds -> [%ExGram.Model.ResponseParameters{retry_after: seconds}]
      end

    error = %ExGram.Error{
      code: 429,
      message: "Too Many Requests",
      metadata: %{parameters: parameters}
    }

    failures = Keyword.fetch!(opts, :failures)

    respond_with(fn _call, attempt ->
      if attempt <= failures,
        do: {:error, error},
        else: {:ok, rich_response([video_block("file-id")])}
    end)
  end

  defp bad_request, do: %ExGram.Error{code: 400, message: "Bad Request"}

  defp rich_response(blocks) do
    %ExGram.Model.Message{message_id: 77, rich_message: %ExGram.Model.RichMessage{blocks: blocks}}
  end

  defp photo_block(file_id) do
    %ExGram.Model.RichBlockPhoto{
      type: "photo",
      photo: [
        %ExGram.Model.PhotoSize{file_id: "#{file_id}-small"},
        %ExGram.Model.PhotoSize{file_id: file_id}
      ]
    }
  end

  defp video_block(file_id) do
    %ExGram.Model.RichBlockVideo{type: "video", video: %ExGram.Model.Video{file_id: file_id}}
  end

  defp post_titled(title), do: %Lolek.Post{title: title}

  defp tmp_file(name, contents) do
    dir =
      Path.join(System.tmp_dir!(), "lolek-send-file-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp name_max(path) do
    case System.cmd("getconf", ["NAME_MAX", path], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      {output, status} -> flunk("getconf NAME_MAX #{path} failed with #{status}: #{output}")
    end
  end
end
