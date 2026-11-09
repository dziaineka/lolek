defmodule Lolek.PrivateMediaTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc false

    def send_rich_message(chat_id, rich_message, options) do
      record({:rich_post, chat_id, rich_message, options})
      {:ok, Application.fetch_env!(:lolek, :private_media_test_response)}
    end

    def edit_message_text(chat_id, message_id, options) do
      record({:edit_post, chat_id, message_id, options})
      {:ok, Application.fetch_env!(:lolek, :private_media_test_response)}
    end

    def edit_message_reply_markup(chat_id, message_id, options) do
      record({:buttons, chat_id, message_id, options[:reply_markup]})
      Application.get_env(:lolek, :private_media_test_result, {:ok, true})
    end

    def send_video(chat_id, file_id, options) do
      record({:video, chat_id, file_id, options})
      Application.get_env(:lolek, :private_media_test_result, {:ok, true})
    end

    def send_photo(chat_id, file_id, options) do
      record({:photo, chat_id, file_id, options})
      Application.fetch_env!(:lolek, :private_media_test_result)
    end

    def send_media_group(chat_id, media, options) do
      record({:album, chat_id, media, options})
      Application.fetch_env!(:lolek, :private_media_test_result)
    end

    def delete_message(chat_id, message_id) do
      record({:delete_message, chat_id, message_id})
      Application.fetch_env!(:lolek, :private_media_test_delete).()
    end

    defp record(call), do: send(Application.fetch_env!(:lolek, :private_media_test_parent), call)
  end

  setup %{tmp_dir: dir} do
    settings = [
      telegram_client: TelegramClient,
      private_media_test_parent: self(),
      private_media_test_result: {:ok, true},
      private_media_test_delete: fn -> {:ok, true} end,
      private_media_test_response: response([video("cached-video")]),
      download_path: dir,
      post_source_caption: false,
      post_requester_caption: true,
      max_message_delay_seconds: 300
    ]

    saved = Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:lolek, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lolek, key, value) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)
    end)

    start_supervised!({Registry, keys: :unique, name: Lolek.UrlProcessingRegistry})
    start_supervised!({Lolek.ChatRateLimiter, limit: 3})
    start_supervised!(Lolek.ProcessingLimiter)
    :ok
  end

  @moduletag :tmp_dir

  for type <- ["group", "supergroup"] do
    test "opens a #{type} post's video privately without another upload", %{tmp_dir: dir} do
      url = cache_post(dir)
      message = message(-100, unquote(type), url)
      message = %{message | is_topic_message: true, message_thread_id: 10}

      assert :ok = Lolek.Handler.handle({:text, url, message}, context())
      assert_receive {:rich_post, -100, _, options}
      assert options[:message_thread_id] == 10
      assert_receive {:edit_post, -100, 77, _}
      token = button_token("Get media privately")

      assert :ok = start_link(123, "private", token)
      assert_receive {:video, 123, "cached-video", []}
      assert_receive {:delete_message, 123, 1}
      refute_receive {:rich_post, 123, _, _}

      # Another group member can use the same link; it is not tied to the requester.
      assert :ok = start_link(456, "private", token)
      assert_receive {:video, 456, "cached-video", []}
      assert_receive {:delete_message, 456, 1}
    end
  end

  test "offers a forwardable video in the same private chat", %{tmp_dir: dir} do
    url = cache_post(dir)
    message = message(123, "private", url)

    assert :ok = Lolek.Handler.handle({:text, url, message}, context())
    assert_receive {:rich_post, 123, _, _}
    token = button_token("Get media privately", 123)

    assert :ok = start_link(123, "private", token)
    assert_receive {:video, 123, "cached-video", []}
    assert_receive {:delete_message, 123, 1}
  end

  test "offers a channel post's media in private", %{tmp_dir: dir} do
    url = cache_post(dir)
    message = %{message(-100, "channel", url) | from: nil}

    assert :ok = Lolek.Handler.handle({:text, url, message}, context())
    assert_receive {:rich_post, -100, _, _}
    token = button_token("Get media privately")

    assert :ok = start_link(123, "private", token)
    assert_receive {:video, 123, "cached-video", []}
    assert_receive {:delete_message, 123, 1}
  end

  test "returns all media from a mixed post, in order" do
    photo = %ExGram.Model.RichBlockPhoto{
      type: "photo",
      photo: [%ExGram.Model.PhotoSize{file_id: "photo"}]
    }

    collage = %ExGram.Model.RichBlockCollage{
      type: "collage",
      blocks: [video("first"), photo, video("second")]
    }

    Application.put_env(:lolek, :private_media_test_response, response([collage]))
    entries = [{"first", ".mp4"}, {"photo", ".jpg"}, {"second", ".mp4"}]

    assert {:ok, _} =
             Lolek.send_file(-100, {:ready_media, entries},
               private_media_bot_username: "lolek_bot"
             )

    assert_receive {:rich_post, -100, _, _}
    token = button_token("Get media privately")
    assert :ok = start_link(123, "private", token)

    assert_receive {:album, 123, album, []}

    assert Enum.map(album, &{&1.type, &1.media, &1.caption}) ==
             [{"video", "first", nil}, {"photo", "photo", nil}, {"video", "second", nil}]

    assert_receive {:delete_message, 123, 1}
    refute_receive {:video, _, _, _}
    refute_receive {:photo, _, _, _}
  end

  test "omits the button when there is no media" do
    assert :ok = Lolek.PrivateMedia.attach(-100, 77, [], "lolek_bot")
    refute_receive {:buttons, _, _, _}
  end

  for ids <- [["photo"], ["first", "second"]] do
    test "delivers #{length(ids)} photos without captions" do
      ids = unquote(ids)
      entries = Enum.map(ids, &{".jpg", &1})
      assert :ok = Lolek.PrivateMedia.attach(-100, 77, entries, "lolek_bot")
      token = button_token("Get media privately")

      assert :ok = start_link(123, "private", token)

      if length(ids) == 1 do
        assert_receive {:photo, 123, "photo", []}
      else
        assert_receive {:album, 123, album, []}

        assert Enum.map(album, &{&1.type, &1.media, &1.caption}) ==
                 Enum.map(ids, &{"photo", &1, nil})
      end

      assert_receive {:delete_message, 123, 1}
    end
  end

  for {count, sizes} <- [{10, [10]}, {11, [9, 2]}, {21, [10, 9, 2]}, {50, [10, 10, 10, 10, 10]}] do
    test "sends #{count} items as complete albums in order" do
      ids = Enum.map(1..unquote(count), &Integer.to_string/1)
      entries = Enum.map(ids, &{".jpg", &1})
      assert :ok = Lolek.PrivateMedia.attach(-100, 77, entries, "lolek_bot")
      token = button_token("Get media privately")
      assert :ok = start_link(123, "private", token)

      delivered =
        for size <- unquote(sizes) do
          assert_receive {:album, 123, album, []}
          assert length(album) == size
          Enum.map(album, & &1.media)
        end

      assert List.flatten(delivered) == ids
      assert_receive {:delete_message, 123, 1}
      refute_receive {:photo, _, _, _}
    end
  end

  test "keeps the command when an album fails" do
    assert :ok =
             Lolek.PrivateMedia.attach(-100, 77, [{".jpg", "one"}, {".mp4", "two"}], "lolek_bot")

    token = button_token("Get media privately")
    Application.put_env(:lolek, :private_media_test_result, {:error, :unavailable})

    assert answer_text(start_link(123, "private", token)) =~ "couldn't send the media"
    assert_receive {:album, 123, _, []}
    refute_receive {:delete_message, _, _}
  end

  test "keeps the request when a photo cannot be delivered" do
    assert :ok = Lolek.PrivateMedia.attach(-100, 77, [{".jpg", "photo"}], "lolek_bot")
    token = button_token("Get media privately")
    Application.put_env(:lolek, :private_media_test_result, {:error, :unavailable})

    assert answer_text(start_link(123, "private", token)) =~ "couldn't send the media"
    refute_receive {:delete_message, _, _}
  end

  test "links a newly uploaded video using the ID returned by Telegram", %{tmp_dir: dir} do
    {:ok, _apps} = Application.ensure_all_started(:erlexec)
    path = Path.join(dir, "video.mp4")
    File.write!(path, "video")

    assert {:ok, {:sent_media, _, [{".mp4", "cached-video"}]}} =
             Lolek.send_file(-100, {:prepared_media, dir, [path]},
               private_media_bot_username: "lolek_bot"
             )

    token = button_token("Get media privately")
    assert :ok = start_link(123, "private", token)
    assert_receive {:video, 123, "cached-video", []}
  end

  test "keeps the group post successful when the button cannot be attached" do
    Application.put_env(:lolek, :private_media_test_result, {:error, :unavailable})

    assert {:ok, _} =
             Lolek.send_file(-100, {:ready_media, [{"cached-video", ".mp4"}]},
               private_media_bot_username: "lolek_bot"
             )

    assert_receive {:rich_post, -100, _, _}
  end

  test "explains links removed by cache cleanup" do
    token = create_link()

    assert :ok =
             Lolek.FileCleaner.cleanup_downloads_directory(
               Application.fetch_env!(:lolek, :download_path),
               0
             )

    result = start_link(123, "private", token)
    assert answer_text(result) =~ "expired"
    refute_receive {:video, _, _, _}
    refute_receive {:delete_message, _, _}
  end

  test "rejects malformed tokens and does not redeem links in groups" do
    for token <- ["../outside", "", String.duplicate("a", 65)] do
      assert answer_text(start_link(123, "private", token)) =~ "expired"
    end

    token = create_link()
    assert %ExGram.Cnt{} = start_link(-100, "supergroup", token)
    refute_receive {:video, _, _, _}
    refute_receive {:delete_message, _, _}
  end

  test "reports send failures and rate limits private requests" do
    token = create_link()
    Application.put_env(:lolek, :private_media_test_result, {:error, :unavailable})
    assert answer_text(start_link(123, "private", token)) =~ "couldn't send"

    assert Lolek.ChatRateLimiter.admit?(123)
    assert Lolek.ChatRateLimiter.admit?(123)
    assert answer_text(start_link(123, "private", token)) =~ "Too many requests"
    refute_receive {:delete_message, _, _}
  end

  test "keeps successful deliveries successful when command deletion fails" do
    token = create_link()

    for fail <- [fn -> {:error, :denied} end, fn -> raise "connection failed" end] do
      Application.put_env(:lolek, :private_media_test_delete, fail)

      assert :ok = start_link(123, "private", token)
      assert_receive {:video, 123, "cached-video", []}
      assert_receive {:delete_message, 123, 1}
    end
  end

  test "leaves ordinary start commands alone" do
    message = message(123, "private", "")
    result = Lolek.Handler.handle({:command, :start, message}, context())

    assert answer_text(result) =~ "Hi!"
    refute_receive {:delete_message, _, _}
  end

  defp cache_post(dir) do
    url = "https://coub.com/view/private-media-test"
    folder = Path.join(dir, Lolek.Url.to_folder_name(url))
    File.mkdir_p!(folder)

    File.write!(
      Path.join(folder, "post.json"),
      Jason.encode!(Lolek.Post.to_map(Lolek.Post.empty(url)))
    )

    assert :ok =
             Lolek.File.move_to_ready_to_telegram(
               {:sent_media, folder, [{".mp4", "cached-video"}]}
             )

    url
  end

  defp create_link do
    :ok = Lolek.PrivateMedia.attach(-100, 77, [{".mp4", "cached-video"}], "lolek_bot")
    button_token("Get media privately")
  end

  defp button_token(label, chat_id \\ -100) do
    assert_receive {:buttons, ^chat_id, 77, %{inline_keyboard: [[button]]}}
    assert button.text == label
    assert %URI{host: "t.me", path: "/lolek_bot", query: query} = URI.parse(button.url)
    assert %{"start" => "media_" <> token = payload} = URI.decode_query(query)
    assert byte_size(payload) <= 64
    token
  end

  defp start_link(chat_id, type, token) do
    # ExGram strips the command name and passes its argument in message.text.
    message = message(chat_id, type, "media_#{token}")
    Lolek.Handler.handle({:command, :start, message}, context())
  end

  defp answer_text(%ExGram.Cnt{answers: [{:response, %{text: text}}]}), do: text

  defp context do
    %ExGram.Cnt{bot_info: %ExGram.Model.User{username: "lolek_bot"}}
  end

  defp message(chat_id, type, text) do
    %ExGram.Model.Message{
      message_id: 1,
      date: System.system_time(:second),
      chat: %ExGram.Model.Chat{id: chat_id, type: type},
      from: %ExGram.Model.User{id: 123, first_name: "Alice"},
      text: text
    }
  end

  defp response(blocks) do
    %ExGram.Model.Message{message_id: 77, rich_message: %ExGram.Model.RichMessage{blocks: blocks}}
  end

  defp video(id) do
    %ExGram.Model.RichBlockVideo{type: "video", video: %ExGram.Model.Video{file_id: id}}
  end
end
