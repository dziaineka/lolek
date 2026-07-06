defmodule Lolek.SendFileTest do
  use ExUnit.Case

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
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def edit_message_caption(chat_id, message_id, options) do
      record_call({:edit_message_caption, chat_id, message_id, options})
      Application.fetch_env!(:lolek, :telegram_test_result)
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
               Lolek.send_file(123, {:ready_to_telegram, "/tmp/file-id.mp4"})
    end)
  end

  test "returns an error when Telegram raises while sending" do
    preserve_telegram_env(fn ->
      error = %ExGram.Error{code: 500, message: "Internal Error"}

      Application.put_env(:lolek, :telegram_client, Lolek.SendFileTest.RaisingTelegramClient)
      Application.put_env(:lolek, :telegram_test_error, error)

      assert {:error, {:telegram_api, %ExGram.Error{code: 500, message: "Internal Error"}}} =
               Lolek.send_file(123, {:ready_to_telegram, "/tmp/file-id.mp4"})
    end)
  end

  test "returns an error for unexpected Telegram upload responses" do
    preserve_telegram_env(fn ->
      response = %ExGram.Model.Message{}

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})

      assert {:error, {:unexpected_telegram_response, ^response}} =
               Lolek.send_file(123, {:compressed, "/tmp/downloaded.txt"})
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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path})
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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path})

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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, "file://" <> encoded_path, _options}

      upload_file_name = encoded_path |> URI.decode() |> Path.basename()
      assert byte_size(upload_file_name) <= max_upload_file_name_bytes
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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path})

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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

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

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "A Video Title.mp4"},
                      _options}
    end)
  end

  test "adds requester and elapsed time to uploaded video captions" do
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

      context = [requester_name: "alice", started_at: System.monotonic_time()]

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert options[:caption] =~ ~r/^alice requested, processed in \d+\.\ds$/

      assert_receive {:edit_message_caption, 123, 456, edit_options}
      assert edit_options[:caption] =~ ~r/^alice requested, processed in \d+\.\ds$/
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

      context = [
        source_caption: "Source post text",
        requester_name: "alice",
        started_at: System.monotonic_time()
      ]

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      refute options[:caption] =~ "Source post text"
      assert options[:caption] =~ ~r/^alice requested, processed in \d+\.\ds$/
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

      context = [
        source_caption: "Source post text\nsecond line",
        requester_name: "alice",
        started_at: System.monotonic_time()
      ]

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert options[:caption] =~
               ~r/^Source post text\nsecond line\n\nalice requested, processed in \d+\.\ds$/
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

      context = [
        source_caption: String.duplicate("a", 2_000),
        requester_name: "alice",
        started_at: System.monotonic_time()
      ]

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path}, context)

      assert_receive {:send_video, 123, {:file_content, %File.Stream{}, "downloaded.mp4"},
                      options}

      assert String.length(options[:caption]) == 1024
      assert options[:caption] =~ ~r/\.\.\.\n\nalice requested, processed in \d+\.\ds$/
    end)
  end

  defp preserve_telegram_env(fun) do
    client = Application.fetch_env(:lolek, :telegram_client)
    result = Application.fetch_env(:lolek, :telegram_test_result)
    error = Application.fetch_env(:lolek, :telegram_test_error)
    parent = Application.fetch_env(:lolek, :telegram_test_parent)
    local_file_uploads = Application.fetch_env(:lolek, :telegram_local_file_uploads)
    post_source_caption = Application.fetch_env(:lolek, :post_source_caption)
    post_requester_caption = Application.fetch_env(:lolek, :post_requester_caption)

    try do
      fun.()
    after
      restore_app_env(:telegram_client, client)
      restore_app_env(:telegram_test_result, result)
      restore_app_env(:telegram_test_error, error)
      restore_app_env(:telegram_test_parent, parent)
      restore_app_env(:telegram_local_file_uploads, local_file_uploads)
      restore_app_env(:post_source_caption, post_source_caption)
      restore_app_env(:post_requester_caption, post_requester_caption)
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
  def edit_message_caption(_chat_id, _message_id, _options) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end
end
