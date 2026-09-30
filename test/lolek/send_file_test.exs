defmodule Lolek.SendFileTest do
  use ExUnit.Case

  @requester %ExGram.Model.User{id: 7, is_bot: false, first_name: "Alice", username: "alice"}

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
    :ok
  end

  defmodule TelegramClient do
    @moduledoc false

    @behaviour Lolek.Telegram

    @impl true
    def send_video(chat_id, video, options) do
      record_call({:send_video, chat_id, video, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def send_document(chat_id, document, options) do
      record_call({:send_document, chat_id, document, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def send_photo(chat_id, photo, options) do
      record_call({:send_photo, chat_id, photo, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def send_animation(chat_id, animation, options) do
      record_call({:send_animation, chat_id, animation, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def send_media_group(chat_id, media, options) do
      record_call({:send_media_group, chat_id, media, options})

      local_files_exist =
        Enum.map(media, fn
          %{media: "file://" <> encoded_path} -> encoded_path |> URI.decode() |> File.exists?()
          _ -> :not_local
        end)

      record_call({:send_media_group_local_files_exist, local_files_exist})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def set_message_reaction(chat_id, message_id, options) do
      record_call({:set_message_reaction, chat_id, message_id, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    # Rejected unless a test sets a rich result, so the tests of the classic
    # sending path reach it through the fallback.
    @impl true
    def send_rich_message(chat_id, rich_message, options) do
      record_call({:send_rich_message, chat_id, rich_message, options})

      Application.get_env(
        :lolek,
        :telegram_test_rich_result,
        {:error, %ExGram.Error{code: 400, message: "Bad Request: rich message rejected"}}
      )
    end

    @impl true
    def delete_message(chat_id, message_id) do
      record_call({:delete_message, chat_id, message_id})
      {:ok, true}
    end

    defp record_call(call) do
      if parent = Application.get_env(:lolek, :telegram_test_parent) do
        send(parent, call)
      end
    end
  end

  test "returns an error when Telegram rejects a ready file" do
    preserve_telegram_env(fn ->
      error = %ExGram.Error{code: 400, message: "Bad Request"}

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:error, error})

      assert {:error, {:telegram_api, %ExGram.Error{code: 400, message: "Bad Request"}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
    end)
  end

  test "does not start a Telegram request after the processing deadline" do
    preserve_telegram_env(fn ->
      test_pid = self()

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, %ExGram.Model.Message{}})
      Application.put_env(:lolek, :telegram_test_parent, test_pid)

      assert {:error, :processing_deadline_exceeded} =
               Lolek.ProcessingDeadline.run(
                 fn ->
                   # Model a command being cooperatively cancelled by the deadline. This lets the
                   # worker unwind far enough to attempt the upload after its deadline has elapsed.
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
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "waits out a flood limit and sends the media on the retry" do
    preserve_telegram_env(fn ->
      flood_wait_env(retry_after: 0)

      assert {:ok, {:ready_media, [{"file-id", ".mp4"}]}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_video, 123, "file-id", _}
      assert_receive {:send_video, 123, "file-id", _}
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "gives up on a flood limit that repeats" do
    preserve_telegram_env(fn ->
      flood_wait_env(retry_after: 0, failures: 2)

      assert {:error, {:telegram_api, %ExGram.Error{code: 429}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_video, 123, "file-id", _}
      assert_receive {:send_video, 123, "file-id", _}
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "does not wait for a flood limit longer than the processing deadline" do
    preserve_telegram_env(fn ->
      flood_wait_env(retry_after: 59)
      test_pid = self()

      Lolek.ProcessingDeadline.run(
        fn ->
          result = Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
          send(test_pid, {:flood_result, result})
        end,
        200
      )

      assert_receive {:flood_result, {:error, {:telegram_api, %ExGram.Error{code: 429}}}}
      assert_receive {:send_video, 123, "file-id", _}
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "a rejection that is not a flood limit is returned at once" do
    preserve_telegram_env(fn ->
      flood_wait_env(retry_after: 0)

      Application.put_env(:lolek, :telegram_test_error, %ExGram.Error{
        code: 400,
        message: "Bad Request"
      })

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_video, 123, "file-id", _}
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "a flood limit without the retry hint is not waited out" do
    preserve_telegram_env(fn ->
      flood_wait_env(retry_after: nil)

      assert {:error, {:telegram_api, %ExGram.Error{code: 429}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})

      assert_receive {:send_video, 123, "file-id", _}
      refute_receive {:send_video, _, _, _}
    end)
  end

  test "returns an error when Telegram raises while sending" do
    preserve_telegram_env(fn ->
      error = %ExGram.Error{code: 500, message: "Internal Error"}

      Application.put_env(:lolek, :telegram_client, Lolek.SendFileTest.RaisingTelegramClient)
      Application.put_env(:lolek, :telegram_test_error, error)

      assert {:error, {:telegram_api, %ExGram.Error{code: 500, message: "Internal Error"}}} =
               Lolek.send_file(123, {:ready_media, [{"file-id", ".mp4"}]})
    end)
  end

  test "returns an error for unexpected Telegram upload responses" do
    preserve_telegram_env(fn ->
      response = %ExGram.Model.Message{}

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})

      assert {:error, {:unexpected_telegram_response, ^response}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", ["/tmp/downloaded.txt"]})
    end)
  end

  test "returns sent file state with uploaded Telegram file id" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.txt", "media")

      response = %ExGram.Model.Message{
        document: %ExGram.Model.Document{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})

      assert {:ok, {:sent_media, _, [{".txt", "telegram-file-id"}]}} =
               Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})
    end)
  end

  test "sends uploaded media to the originating message thread" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())

      context = [message_thread_id: 456]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, _upload, options}
      assert options[:message_thread_id] == 456
    end)
  end

  test "sends media groups to the originating message thread" do
    preserve_telegram_env(fn ->
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..2 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :telegram_test_parent, self())

      context = [message_thread_id: 456]

      assert {:ok, {:sent_media, "/tmp", _entries}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files}, context)

      assert_receive {:send_media_group, 123, _media, options}
      assert options[:message_thread_id] == 456
    end)
  end

  test "limits a gallery to the configured maximum number of media files" do
    preserve_telegram_env(fn ->
      files = for index <- 1..3, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..2 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :max_gallery_media, 2)

      assert {:ok, {:sent_media, "/tmp", entries}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert length(entries) == 2
      assert_receive {:send_media_group, 123, media, []}
      assert length(media) == 2
      refute_receive {:send_media_group, 123, _, []}
    end)
  end

  test "sends a gallery reduced to one video through the video endpoint" do
    preserve_telegram_env(fn ->
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "gallery-video-file"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :max_gallery_media, 1)

      assert {:ok, {:sent_media, "/tmp", [{".mp4", "gallery-video-file"}]}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "gallery-1.mp4"},
                      _options}

      refute_receive {:send_media_group, 123, _, []}
    end)
  end

  test "sends one-item galleries as local file uris" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("gallery video.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "gallery-video-file"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      assert {:ok, {:sent_media, "/tmp", [{".mp4", "gallery-video-file"}]}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", [file_path]})

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}
      assert URI.decode(encoded_path) == file_path
    end)
  end

  test "sends media groups as local file uris and cleans upload aliases" do
    preserve_telegram_env(fn ->
      files = for index <- 1..2, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..2 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      context = [source_title: "Gallery title"]

      assert {:ok, {:sent_media, "/tmp", _entries}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files}, context)

      assert_receive {:send_media_group, 123, media, []}
      assert Enum.all?(media, &String.starts_with?(&1.media, "file://"))
      assert_receive {:send_media_group_local_files_exist, [true, true]}

      for file <- files do
        assert [] = Path.wildcard(Path.join(Path.dirname(file), ".telegram-upload-*"))
      end
    end)
  end

  test "cleans prepared gallery uploads when a later item cannot be prepared" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("gallery-1.jpg", "media")
      missing_path = Path.join(Path.dirname(file_path), "missing.jpg")

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, []})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      context = [source_title: "Gallery title"]

      assert {:error, {:local_upload_alias, :enoent}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, "/tmp", [file_path, missing_path]},
                 context
               )

      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
      refute_receive {:send_media_group, _, _, _}
    end)
  end

  test "builds uploaded and cached gallery media through the same type mapping" do
    preserve_telegram_env(fn ->
      files = [
        tmp_file("gallery.jpg", "photo"),
        tmp_file("gallery.mp4", "video"),
        tmp_file("gallery.gif", "animation")
      ]

      messages = [
        %ExGram.Model.Message{photo: [%ExGram.Model.PhotoSize{file_id: "photo-id"}]},
        %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: "video-id"}},
        %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: "gif-id"}}
      ]

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :telegram_test_parent, self())

      assert {:ok,
              {:sent_media, "/tmp",
               [{".jpg", "photo-id"}, {".mp4", "video-id"}, {".gif", "gif-id"}]}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert_receive {:send_media_group, 123, uploaded_media, []}

      assert [
               %ExGram.Model.InputMediaPhoto{media: {:file_content, _, "gallery.jpg"}},
               %ExGram.Model.InputMediaVideo{media: {:file_content, _, "gallery.mp4"}},
               %ExGram.Model.InputMediaDocument{media: {:file_content, _, "gallery.gif"}}
             ] = uploaded_media

      cached_entries = [{"photo-id", ".jpg"}, {"video-id", ".mp4"}, {"gif-id", ".gif"}]

      assert {:ok, {:ready_media, ^cached_entries}} =
               Lolek.send_file(123, {:ready_media, cached_entries})

      assert_receive {:send_media_group, 123, cached_media, []}

      assert [
               %ExGram.Model.InputMediaPhoto{media: "photo-id"},
               %ExGram.Model.InputMediaVideo{media: "video-id"},
               %ExGram.Model.InputMediaDocument{media: "gif-id"}
             ] = cached_media
    end)
  end

  test "applies the gallery limit to cached media" do
    preserve_telegram_env(fn ->
      entries = for index <- 1..3, do: {"gallery-file-#{index}", ".jpg"}
      response = %ExGram.Model.Message{photo: [%ExGram.Model.PhotoSize{file_id: "new-file-id"}]}

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :max_gallery_media, 1)

      assert {:ok, {:ready_media, limited_entries}} =
               Lolek.send_file(123, {:ready_media, entries})

      assert length(limited_entries) == 1
      assert_receive {:send_photo, 123, "gallery-file-1", []}
      refute_receive {:send_media_group, 123, _, []}
    end)
  end

  test "propagates Telegram errors when sending cached galleries" do
    preserve_telegram_env(fn ->
      error = %ExGram.Error{code: 400, message: "Bad Request"}
      entries = [{"gallery-file-1", ".jpg"}, {"gallery-file-2", ".jpg"}]

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:error, error})
      Application.put_env(:lolek, :telegram_test_parent, self())

      assert {:error, {:telegram_api, %ExGram.Error{code: 400, message: "Bad Request"}}} =
               Lolek.send_file(123, {:ready_media, entries})

      assert_receive {:send_media_group, 123, _media, []}
    end)
  end

  test "splits large collections without a one-item media group" do
    preserve_telegram_env(fn ->
      files = for index <- 1..11, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..9 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :max_gallery_media, 11)

      assert {:ok, {:sent_media, "/tmp", entries}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert length(entries) == 11
      assert_receive {:send_media_group, 123, first_batch, []}
      assert_receive {:send_media_group, 123, second_batch, []}
      assert length(first_batch) == 9
      assert length(second_batch) == 2
    end)
  end

  test "keeps a gallery half that already reached the chat" do
    preserve_telegram_env(fn ->
      files = for index <- 1..11, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..9 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, Lolek.SendFileTest.GalleryTailFailsClient)
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_test_attempts, :atomics.new(1, []))
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :max_gallery_media, 11)

      assert {:ok, {:sent_media, "/tmp", entries}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})

      assert length(entries) == 9
      assert_receive {:send_media_group, 123, first_batch, []}
      assert_receive {:send_media_group, 123, second_batch, []}
      assert length(first_batch) == 9
      assert length(second_batch) == 2
    end)
  end

  test "reports a partly sent album as a failure in the delete mode" do
    preserve_telegram_env(fn ->
      files = for index <- 1..11, do: tmp_file("gallery-#{index}.jpg", "media")

      messages =
        for index <- 1..9 do
          %ExGram.Model.Message{
            photo: [%ExGram.Model.PhotoSize{file_id: "gallery-file-#{index}"}]
          }
        end

      Application.put_env(:lolek, :telegram_client, Lolek.SendFileTest.GalleryTailFailsClient)
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_test_attempts, :atomics.new(1, []))
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :max_gallery_media, 11)

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files},
                 source_message_mode: :delete,
                 source_message_id: 99
               )

      assert_receive {:send_media_group, 123, _first_batch, _options}
      assert_receive {:send_media_group, 123, _second_batch, _options}
    end)
  end

  test "sends galleries above the rich message limit the classic way" do
    preserve_telegram_env(fn ->
      entries = for index <- 1..51, do: {"photo-#{index}", ".jpg"}

      messages =
        for index <- 1..10 do
          %ExGram.Model.Message{photo: [%ExGram.Model.PhotoSize{file_id: "photo-#{index}"}]}
        end

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
      Application.put_env(:lolek, :max_gallery_media, 51)

      assert {:ok, {:ready_media, ^entries}} = Lolek.send_file(123, {:ready_media, entries})

      assert_receive {:send_media_group, 123, _batch, _options}
      refute_receive {:send_rich_message, _, _, _}
    end)
  end

  test "reports an error when the first media group never lands" do
    preserve_telegram_env(fn ->
      files = for index <- 1..11, do: tmp_file("gallery-#{index}.jpg", "media")

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :max_gallery_media, 11)

      Application.put_env(
        :lolek,
        :telegram_test_result,
        {:error, %ExGram.Error{code: 400, message: "Bad Request"}}
      )

      assert {:error, {:telegram_api, %ExGram.Error{code: 400}}} =
               Lolek.send_file(123, {:prepared_media, "/tmp", files})
    end)
  end

  test "sends local file uris when local Telegram uploads are enabled" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded with spaces.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}
      assert encoded_path == String.replace(file_path, " ", "%20")
    end)
  end

  test "uses source titles as local upload file names" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("compressed.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      context = [source_title: "A / Video: https://example.com/watch Title?"]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}

      assert encoded_path |> URI.decode() |> Path.basename() == "A Video Title.mp4"
      assert File.exists?(file_path)
      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
    end)
  end

  test "keeps local upload file names within conservative and filesystem byte limits" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("compressed.mp4", "media")
      extname = Path.extname(file_path)
      max_upload_file_name_bytes = min(180, name_max(Path.dirname(file_path)))
      # A three-byte character makes the title budget land in the middle of a
      # codepoint unless truncation accounts for UTF-8 boundaries.
      source_title = String.duplicate("€", 100)

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      context = [source_title: source_title]

      assert byte_size(source_title <> extname) > max_upload_file_name_bytes

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}

      upload_file_name = encoded_path |> URI.decode() |> Path.basename()
      assert byte_size(upload_file_name) <= max_upload_file_name_bytes
      assert String.valid?(upload_file_name)
      assert String.ends_with?(upload_file_name, extname)
      assert File.exists?(file_path)
      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
    end)
  end

  test "keeps local upload file names within byte limits after Unicode decomposition" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("compressed.mp4", "media")
      extname = Path.extname(file_path)
      max_upload_file_name_bytes = min(180, name_max(Path.dirname(file_path)))
      # This precomposed character expands under NFD, so original-byte truncation
      # can still produce a name that is too long after filesystem decomposition.
      source_title = String.duplicate("Ǖ", 100)

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :telegram_local_file_uploads, true)

      context = [source_title: source_title]

      assert byte_size(source_title <> extname) > max_upload_file_name_bytes

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}

      upload_file_name = encoded_path |> URI.decode() |> Path.basename()
      assert byte_size(String.normalize(upload_file_name, :nfd)) <= max_upload_file_name_bytes
      assert String.valid?(upload_file_name)
      assert String.ends_with?(upload_file_name, extname)
      assert File.exists?(file_path)
      assert [] = Path.wildcard(Path.join(Path.dirname(file_path), ".telegram-upload-*"))
    end)
  end

  test "streams first video uploads with larger chunks" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

      assert_receive {:send_video, 123,
                      {:file_content, %File.Stream{} = stream, "downloaded.mp4"}, _options}

      assert stream.path == file_path
      assert stream.line_or_bytes == 64 * 1024
    end)
  end

  test "uses source titles as upload file names" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("compressed.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())

      context = [source_title: "A Video Title"]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "A Video Title.mp4"},
                      _options}
    end)
  end

  test "sanitizes source titles before using them as upload file names" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("compressed.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())

      context = [source_title: "A / Video: https://example.com/watch Title?"]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "A Video Title.mp4"},
                      _options}
    end)
  end

  test "mentions the requester in classic captions" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        message_id: 456,
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_requester_caption, true)

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 requester: @requester
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert options[:caption] == "requested by alice"

      assert [
               %ExGram.Model.MessageEntity{
                 type: "text_mention",
                 offset: 13,
                 length: 5,
                 user: @requester
               }
             ] =
               options[:caption_entities]
    end)
  end

  test "writes an unknown sender as plain text in classic captions" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")
      response = %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: "telegram-file-id"}}

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_requester_caption, true)

      Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]},
        requester: nil
      )

      assert_receive {:send_video, 123, _upload, options}
      assert options[:caption] == "requested by Someone"
      assert options[:caption_entities] == nil
    end)
  end

  test "does not include source captions by default" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_source_caption, false)
      Application.put_env(:lolek, :post_requester_caption, true)

      context = [source_caption: "Source post text", requester: @requester]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert options[:caption] == "requested by alice"
    end)
  end

  test "includes source captions when enabled" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_source_caption, true)
      Application.put_env(:lolek, :post_requester_caption, true)

      context = [source_caption: "Source post text\nsecond line", requester: @requester]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert options[:caption] == "Source post text\nsecond line\n\nrequested by alice"
      assert [%ExGram.Model.MessageEntity{offset: 43, length: 5}] = options[:caption_entities]
    end)
  end

  test "truncates source captions while preserving requester captions" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_source_caption, true)
      Application.put_env(:lolek, :post_requester_caption, true)

      context = [source_caption: String.duplicate("a", 2_000), requester: @requester]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert String.length(options[:caption]) == 1024
      assert String.ends_with?(options[:caption], "...\n\nrequested by alice")
      assert [%ExGram.Model.MessageEntity{offset: 1019, length: 5}] = options[:caption_entities]
    end)
  end

  test "truncates Unicode captions by Telegram's UTF-16 limit" do
    preserve_telegram_env(fn ->
      file_path = tmp_file("downloaded.mp4", "media")

      response = %ExGram.Model.Message{
        video: %ExGram.Model.Video{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})
      Application.put_env(:lolek, :telegram_test_parent, self())
      Application.put_env(:lolek, :post_source_caption, true)
      Application.put_env(:lolek, :post_requester_caption, true)

      context = [source_caption: String.duplicate("😀", 2_000), requester: @requester]

      assert {:ok, {:sent_media, _, [{".mp4", "telegram-file-id"}]}} =
               Lolek.send_file(
                 123,
                 {:prepared_media, Path.dirname(file_path), [file_path]},
                 context
               )

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      caption_units = utf16_code_units(options[:caption])
      assert caption_units in 1023..1024
      assert String.ends_with?(options[:caption], "...\n\nrequested by alice")

      assert [%ExGram.Model.MessageEntity{offset: offset, length: 5}] = options[:caption_entities]
      assert offset == caption_units - 5
    end)
  end

  describe "rich posts" do
    test "sends a video as a rich message with the source button" do
      preserve_telegram_env(fn ->
        file_path = tmp_file("downloaded.mp4", "media")
        rich_env(rich_response([video_block("rich-video")]))

        context = [message_thread_id: 456, source_url: "https://example.com/p/1"]

        assert {:ok, {:sent_media, _, [{".mp4", "rich-video"}]}} =
                 Lolek.send_file(
                   123,
                   {:prepared_media, Path.dirname(file_path), [file_path]},
                   context
                 )

        assert_receive {:send_rich_message, 123, rich_message, options}

        assert [
                 %ExGram.Model.InputRichBlockVideo{
                   video: %ExGram.Model.InputMediaVideo{
                     media: {:file_content, %File.Stream{}, "downloaded.mp4"},
                     supports_streaming: true
                   }
                 }
               ] = rich_message.blocks

        assert options[:message_thread_id] == 456
        assert options[:disable_notification] == true

        assert %ExGram.Model.InlineKeyboardMarkup{
                 inline_keyboard: [
                   [
                     %ExGram.Model.InlineKeyboardButton{
                       text: "Original",
                       url: "https://example.com/p/1"
                     }
                   ]
                 ]
               } = options[:reply_markup]

        refute_receive {:send_video, _, _, _}
      end)
    end

    test "sends a gallery as one message and caches ids in media order" do
      preserve_telegram_env(fn ->
        files = [
          tmp_file("gallery-1.jpg", "photo"),
          tmp_file("gallery.gif", "animation"),
          tmp_file("gallery-2.jpg", "photo")
        ]

        rich_env(
          rich_response([
            %{type: "collage", blocks: [photo_block("photo-1"), photo_block("photo-2")]},
            animation_block("gif")
          ])
        )

        assert {:ok, {:sent_media, "/tmp", entries}} =
                 Lolek.send_file(123, {:prepared_media, "/tmp", files})

        assert entries == [{".jpg", "photo-1"}, {".jpg", "photo-2"}, {".gif", "gif"}]

        assert_receive {:send_rich_message, 123, rich_message, options}

        assert [
                 %ExGram.Model.InputRichBlockCollage{blocks: [_, _]},
                 %ExGram.Model.InputRichBlockAnimation{}
               ] = rich_message.blocks

        refute options[:disable_notification]
        refute_receive {:send_media_group, _, _, _}
      end)
    end

    test "sends cached media by file id" do
      preserve_telegram_env(fn ->
        entries = [{"photo-id", ".jpg"}, {"video-id", ".mp4"}]

        rich_env(
          rich_response([
            %{type: "collage", blocks: [photo_block("photo-id"), video_block("video-id")]}
          ])
        )

        assert {:ok, {:ready_media, ^entries}} = Lolek.send_file(123, {:ready_media, entries})

        assert_receive {:send_rich_message, 123, rich_message, _options}

        assert [
                 %ExGram.Model.InputRichBlockCollage{
                   blocks: [
                     %ExGram.Model.InputRichBlockPhoto{photo: %{media: "photo-id"}},
                     %ExGram.Model.InputRichBlockVideo{video: %{media: "video-id"}}
                   ]
                 }
               ] = rich_message.blocks
      end)
    end

    test "sends local file uris in rich messages" do
      preserve_telegram_env(fn ->
        file_path = tmp_file("photo.jpg", "photo")
        rich_env(rich_response([photo_block("rich-photo")]))
        Application.put_env(:lolek, :telegram_local_file_uploads, true)

        assert {:ok, {:sent_media, _, [{".jpg", "rich-photo"}]}} =
                 Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

        assert_receive {:send_rich_message, 123, rich_message, _options}

        assert [%ExGram.Model.InputRichBlockPhoto{photo: %{media: "file://" <> path}}] =
                 rich_message.blocks

        assert URI.decode(path) == file_path
      end)
    end

    test "sends documents the classic way" do
      preserve_telegram_env(fn ->
        file_path = tmp_file("downloaded.txt", "media")
        rich_env(rich_response([]))

        Application.put_env(
          :lolek,
          :telegram_test_result,
          {:ok, %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: "doc"}}}
        )

        assert {:ok, {:sent_media, _, [{".txt", "doc"}]}} =
                 Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

        assert_receive {:send_document, 123, _upload, _options}
        refute_receive {:send_rich_message, _, _, _}
      end)
    end

    test "falls back to the classic way when Telegram rejects the rich post" do
      preserve_telegram_env(fn ->
        rich_env(
          {:error, %ExGram.Error{code: 400, message: "Bad Request: can't parse rich message"}}
        )

        Application.put_env(
          :lolek,
          :telegram_test_result,
          {:ok, %ExGram.Model.Message{photo: [%ExGram.Model.PhotoSize{file_id: "classic"}]}}
        )

        assert {:ok, {:ready_media, [{"photo-id", ".jpg"}]}} =
                 Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]})

        assert_receive {:send_rich_message, 123, _rich_message, _options}
        assert_receive {:send_photo, 123, "photo-id", _options}
      end)
    end

    test "does not resend a post the classic way after other errors" do
      preserve_telegram_env(fn ->
        rich_env({:error, %ExGram.Error{code: 500, message: "Internal Server Error"}})

        assert {:error, {:telegram_api, %ExGram.Error{code: 500}}} =
                 Lolek.send_file(123, {:ready_media, [{"video-id", ".mp4"}]})

        assert_receive {:send_rich_message, 123, _rich_message, _options}
        refute_receive {:send_video, _, _, _}
      end)
    end

    test "skips the cache when the sent post does not match the media" do
      preserve_telegram_env(fn ->
        file_path = tmp_file("downloaded.mp4", "media")
        rich_env(rich_response([]))

        assert {:ok, {:sent_media, _, []}} =
                 Lolek.send_file(123, {:prepared_media, Path.dirname(file_path), [file_path]})

        refute_receive {:send_video, _, _, _}
      end)
    end

    test "leaves out the source button for a link Telegram would refuse as too long" do
      preserve_telegram_env(fn ->
        rich_env(rich_response([photo_block("photo-id")]))
        prefix = "https://www.instagram.com/p/x?q="
        longest = prefix <> String.duplicate("a", 8192 - byte_size(prefix))

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, source_url: longest)
        assert_receive {:send_rich_message, 123, _rich_message, options}
        assert %ExGram.Model.InlineKeyboardMarkup{} = options[:reply_markup]

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, source_url: longest <> "a")
        assert_receive {:send_rich_message, 123, _rich_message, too_long_options}
        refute too_long_options[:reply_markup]
      end)
    end

    test "leaves out the source button for a link without a host" do
      preserve_telegram_env(fn ->
        rich_env(rich_response([photo_block("photo-id")]))

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, source_url: "https:///p/1")

        assert_receive {:send_rich_message, 123, _rich_message, options}
        refute options[:reply_markup]
      end)
    end

    test "adds the description" do
      preserve_telegram_env(fn ->
        rich_env(rich_response([photo_block("photo-id")]))
        Application.put_env(:lolek, :post_source_caption, true)

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, source_caption: "Post text")

        assert_receive {:send_rich_message, 123, rich_message, _options}

        assert [_photo, %ExGram.Model.InputRichBlockParagraph{text: "Post text"}] =
                 rich_message.blocks
      end)
    end
  end

  describe "source message modes" do
    test "raw mode mentions the requester only when enabled" do
      assert footer(:raw, true) == [
               %ExGram.Model.RichTextTextMention{
                 type: "text_mention",
                 text: "alice",
                 user: @requester
               }
             ]

      assert footer(:raw, false) == nil
    end

    test "no requester in the context means no footer" do
      preserve_telegram_env(fn ->
        rich_env(rich_response([photo_block("photo-id")]))
        Application.put_env(:lolek, :post_requester_caption, true)

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, [])

        assert_receive {:send_rich_message, 123, rich_message, _options}
        assert [%ExGram.Model.InputRichBlockPhoto{}] = rich_message.blocks
      end)
    end

    test "reply mode replies without a mention" do
      {blocks, options} = rich_post(:reply, true)

      refute Enum.any?(blocks, &match?(%ExGram.Model.InputRichBlockFooter{}, &1))

      assert %ExGram.Model.ReplyParameters{message_id: 99, allow_sending_without_reply: true} =
               options[:reply_parameters]
    end

    test "delete mode always mentions the requester and does not reply" do
      assert [%ExGram.Model.RichTextTextMention{user: @requester}] = footer(:delete, false)
      {_blocks, options} = rich_post(:delete, false)
      refute options[:reply_parameters]
    end

    test "classic single media replies with the source button" do
      preserve_telegram_env(fn ->
        rich_env({:error, %ExGram.Error{code: 400, message: "Bad Request"}})

        Application.put_env(
          :lolek,
          :telegram_test_result,
          {:ok, %ExGram.Model.Message{photo: [%ExGram.Model.PhotoSize{file_id: "photo-id"}]}}
        )

        Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, mode_context(:reply))

        assert_receive {:send_photo, 123, "photo-id", options}
        assert %ExGram.Model.ReplyParameters{message_id: 99} = options[:reply_parameters]
        assert %ExGram.Model.InlineKeyboardMarkup{} = options[:reply_markup]
      end)
    end

    test "classic albums reply from the first batch and carry no button" do
      preserve_telegram_env(fn ->
        entries = for index <- 1..11, do: {"photo-#{index}", ".jpg"}

        messages =
          for index <- 1..9,
              do: %ExGram.Model.Message{
                photo: [%ExGram.Model.PhotoSize{file_id: "photo-#{index}"}]
              }

        rich_env({:error, %ExGram.Error{code: 400, message: "Bad Request"}})
        Application.put_env(:lolek, :telegram_test_result, {:ok, messages})
        Application.put_env(:lolek, :max_gallery_media, 11)

        Lolek.send_file(123, {:ready_media, entries}, mode_context(:reply))

        assert_receive {:send_media_group, 123, _first, first_options}
        assert_receive {:send_media_group, 123, _second, second_options}
        assert %ExGram.Model.ReplyParameters{message_id: 99} = first_options[:reply_parameters]
        refute second_options[:reply_parameters]
        refute first_options[:reply_markup]
      end)
    end
  end

  defp footer(mode, requester_caption) do
    {blocks, _options} = rich_post(mode, requester_caption)

    Enum.find_value(blocks, fn
      %ExGram.Model.InputRichBlockFooter{text: ["requested by " | mention]} -> mention
      _ -> nil
    end)
  end

  defp rich_post(mode, requester_caption) do
    preserve_telegram_env(fn ->
      rich_env(rich_response([photo_block("photo-id")]))
      Application.put_env(:lolek, :post_requester_caption, requester_caption)

      Lolek.send_file(123, {:ready_media, [{"photo-id", ".jpg"}]}, mode_context(mode))

      assert_receive {:send_rich_message, 123, rich_message, options}
      {rich_message.blocks, options}
    end)
  end

  defp mode_context(mode) do
    [
      requester: @requester,
      source_message_id: 99,
      source_message_mode: mode,
      source_url: "https://example.com/p/1"
    ]
  end

  defp rich_env(rich_result) do
    Application.put_env(:lolek, :telegram_client, TelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())
    Application.put_env(:lolek, :telegram_test_rich_result, rich_result)
  end

  defp rich_response(blocks) do
    ExGram.Cast.cast(
      %{
        message_id: 1,
        date: 0,
        chat: %{id: 123, type: "private"},
        rich_message: %{blocks: blocks}
      },
      ExGram.Model.Message
    )
  end

  defp photo_block(file_id) do
    %{type: "photo", photo: [%{file_id: file_id, file_unique_id: file_id, width: 1, height: 1}]}
  end

  defp video_block(file_id), do: %{type: "video", video: media_file(file_id)}
  defp animation_block(file_id), do: %{type: "animation", animation: media_file(file_id)}

  defp media_file(file_id) do
    %{file_id: file_id, file_unique_id: file_id, width: 1, height: 1, duration: 1}
  end

  # A client that answers with 429 first and succeeds afterwards. `retry_after`
  # of nil models a flood limit Telegram sent without the hint.
  defp flood_wait_env(opts) do
    retry_after = Keyword.fetch!(opts, :retry_after)

    parameters =
      case retry_after do
        nil -> []
        seconds -> [%ExGram.Model.ResponseParameters{retry_after: seconds}]
      end

    Application.put_env(:lolek, :telegram_client, Lolek.SendFileTest.FloodWaitTelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())
    Application.put_env(:lolek, :telegram_test_attempts, :atomics.new(1, []))
    Application.put_env(:lolek, :telegram_test_flood_failures, Keyword.get(opts, :failures, 1))

    Application.put_env(:lolek, :telegram_test_error, %ExGram.Error{
      code: 429,
      message: "Too Many Requests",
      metadata: %{parameters: parameters}
    })

    Application.put_env(
      :lolek,
      :telegram_test_result,
      {:ok, %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: "telegram-file-id"}}}
    )
  end

  defp preserve_telegram_env(fun) do
    client = Application.fetch_env(:lolek, :telegram_client)
    result = Application.fetch_env(:lolek, :telegram_test_result)
    rich_result = Application.fetch_env(:lolek, :telegram_test_rich_result)
    error = Application.fetch_env(:lolek, :telegram_test_error)
    parent = Application.fetch_env(:lolek, :telegram_test_parent)
    local_file_uploads = Application.fetch_env(:lolek, :telegram_local_file_uploads)
    post_source_caption = Application.fetch_env(:lolek, :post_source_caption)
    post_requester_caption = Application.fetch_env(:lolek, :post_requester_caption)
    max_gallery_media = Application.fetch_env(:lolek, :max_gallery_media)

    try do
      fun.()
    after
      restore_app_env(:telegram_client, client)
      restore_app_env(:telegram_test_result, result)
      restore_app_env(:telegram_test_rich_result, rich_result)
      restore_app_env(:telegram_test_error, error)
      restore_app_env(:telegram_test_parent, parent)
      restore_app_env(:telegram_local_file_uploads, local_file_uploads)
      restore_app_env(:post_source_caption, post_source_caption)
      restore_app_env(:post_requester_caption, post_requester_caption)
      restore_app_env(:max_gallery_media, max_gallery_media)
    end
  end

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
      {output, 0} ->
        output
        |> String.trim()
        |> String.to_integer()

      {output, status} ->
        flunk("getconf NAME_MAX #{path} failed with #{status}: #{output}")
    end
  end

  defp utf16_code_units(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:lolek, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:lolek, key)
end

defmodule Lolek.SendFileTest.RaisingTelegramClient do
  @moduledoc false

  @behaviour Lolek.Telegram

  @impl true
  def send_video(_chat_id, _video, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def send_document(_chat_id, _document, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def send_photo(_chat_id, _photo, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def send_animation(_chat_id, _animation, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def send_media_group(_chat_id, _media, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def set_message_reaction(_chat_id, _message_id, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def send_rich_message(_chat_id, _rich_message, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end

  @impl true
  def delete_message(_chat_id, _message_id) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end
end

defmodule Lolek.SendFileTest.FloodWaitTelegramClient do
  @moduledoc """
  Fails the first attempts with a flood limit, then succeeds.
  """

  @behaviour Lolek.Telegram

  @impl true
  def send_video(chat_id, video, options) do
    respond({:send_video, chat_id, video, options})
  end

  @impl true
  def send_document(chat_id, document, options) do
    respond({:send_document, chat_id, document, options})
  end

  @impl true
  def send_photo(chat_id, photo, options) do
    respond({:send_photo, chat_id, photo, options})
  end

  @impl true
  def send_animation(chat_id, animation, options) do
    respond({:send_animation, chat_id, animation, options})
  end

  @impl true
  def send_media_group(chat_id, media, options) do
    respond({:send_media_group, chat_id, media, options})
  end

  @impl true
  def set_message_reaction(chat_id, message_id, options) do
    respond({:set_message_reaction, chat_id, message_id, options})
  end

  # Flood limits are exercised on the classic path; the rich attempt is
  # rejected without counting as one.
  @impl true
  def send_rich_message(_chat_id, _rich_message, _options) do
    {:error, %ExGram.Error{code: 400, message: "Bad Request: rich message rejected"}}
  end

  @impl true
  def delete_message(chat_id, message_id) do
    respond({:delete_message, chat_id, message_id})
  end

  defp respond(call) do
    if parent = Application.get_env(:lolek, :telegram_test_parent) do
      send(parent, call)
    end

    counter = Application.fetch_env!(:lolek, :telegram_test_attempts)
    attempt = :atomics.add_get(counter, 1, 1)
    failures = Application.get_env(:lolek, :telegram_test_flood_failures, 1)

    if attempt <= failures do
      {:error, Application.fetch_env!(:lolek, :telegram_test_error)}
    else
      Application.fetch_env!(:lolek, :telegram_test_result)
    end
  end
end

defmodule Lolek.SendFileTest.GalleryTailFailsClient do
  @moduledoc """
  Takes the first media group and rejects every one after it.
  """

  @behaviour Lolek.Telegram

  @impl true
  def send_video(_chat_id, _video, _options), do: rejected()

  @impl true
  def send_document(_chat_id, _document, _options), do: rejected()

  @impl true
  def send_photo(_chat_id, _photo, _options), do: rejected()

  @impl true
  def send_animation(_chat_id, _animation, _options), do: rejected()

  @impl true
  def set_message_reaction(_chat_id, _message_id, _options), do: rejected()

  @impl true
  def send_rich_message(_chat_id, _rich_message, _options), do: rejected()

  @impl true
  def delete_message(_chat_id, _message_id), do: rejected()

  @impl true
  def send_media_group(chat_id, media, options) do
    if parent = Application.get_env(:lolek, :telegram_test_parent) do
      send(parent, {:send_media_group, chat_id, media, options})
    end

    counter = Application.fetch_env!(:lolek, :telegram_test_attempts)

    case :atomics.add_get(counter, 1, 1) do
      1 -> Application.fetch_env!(:lolek, :telegram_test_result)
      _ -> rejected()
    end
  end

  defp rejected do
    {:error, %ExGram.Error{code: 400, message: "Bad Request"}}
  end
end
