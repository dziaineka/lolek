defmodule Lolek.TelegramTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc false

    @spec set_message_reaction(integer(), integer(), keyword()) :: {:ok, true}
    def set_message_reaction(chat_id, message_id, options) do
      send(Application.fetch_env!(:lolek, :telegram_test_parent), {
        :set_message_reaction,
        chat_id,
        message_id,
        options
      })

      {:ok, true}
    end

    @spec send_rich_message(integer(), term(), keyword()) :: {:ok, :sent}
    def send_rich_message(chat_id, rich_message, options) do
      send(
        Application.fetch_env!(:lolek, :telegram_test_parent),
        {:send_rich_message, chat_id, rich_message, options}
      )

      {:ok, :sent}
    end

    @spec delete_message(integer(), integer()) :: {:ok, true}
    def delete_message(chat_id, message_id) do
      send(Application.fetch_env!(:lolek, :telegram_test_parent), {
        :delete_message,
        chat_id,
        message_id
      })

      {:ok, true}
    end
  end

  defmodule PathAdapter do
    @moduledoc false
    @behaviour ExGram.Adapter

    @impl true
    @spec request(atom(), String.t(), {:multipart, [tuple()]}, keyword()) :: {:ok, map()}
    def request(_verb, path, {:multipart, _parts}, _opts) do
      send(Application.fetch_env!(:lolek, :telegram_test_parent), {:adapter_request, path})
      {:ok, %{message_id: 1, date: 0, chat: %{id: 42, type: "private"}}}
    end
  end

  setup do
    telegram_client = Application.get_env(:lolek, :telegram_client)
    telegram_test_parent = Application.get_env(:lolek, :telegram_test_parent)

    Application.put_env(:lolek, :telegram_client, TelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())

    on_exit(fn ->
      restore_app_env(:telegram_client, telegram_client)
      restore_app_env(:telegram_test_parent, telegram_test_parent)
    end)
  end

  test "sets a reaction on a Telegram message" do
    reaction = [%ExGram.Model.ReactionTypeEmoji{type: "emoji", emoji: "🐳"}]

    assert {:ok, true} =
             Lolek.Telegram.set_message_reaction(123, 456, reaction: reaction, is_big: true)

    assert_receive {:set_message_reaction, 123, 456, [reaction: ^reaction, is_big: true]}
  end

  test "sends rich messages and deletes messages through the client" do
    rich_message = %ExGram.Model.InputRichMessage{blocks: []}

    assert {:ok, :sent} = Lolek.Telegram.send_rich_message(1, rich_message, message_thread_id: 7)
    assert_receive {:send_rich_message, 1, ^rich_message, [message_thread_id: 7]}

    assert {:ok, true} = Lolek.Telegram.delete_message(1, 42)
    assert_receive {:delete_message, 1, 42}
  end

  describe "rich message multipart" do
    test "uploads nested files as attach:// parts" do
      rich_message = %ExGram.Model.InputRichMessage{
        blocks: [
          %ExGram.Model.InputRichBlockCollage{
            type: "collage",
            blocks: [
              photo_block({:file_content, "photo bytes", "a.jpg"}),
              photo_block("CACHED_FILE_ID")
            ]
          },
          %ExGram.Model.InputRichBlockVideo{
            type: "video",
            video: %ExGram.Model.InputMediaVideo{type: "video", media: {:file, "/tmp/v.mp4"}}
          }
        ]
      }

      reply_parameters = %ExGram.Model.ReplyParameters{message_id: 5}

      assert {:multipart, parts} =
               Lolek.ExGramTelegram.rich_message_multipart(42, rich_message,
                 reply_parameters: reply_parameters,
                 message_thread_id: 3
               )

      assert {:file_content, "file0", "photo bytes", "a.jpg"} in parts
      assert {:file, "file1", "/tmp/v.mp4"} in parts
      assert {"chat_id", "42"} in parts
      assert {"message_thread_id", "3"} in parts

      {"reply_parameters", reply_json} = List.keyfind(parts, "reply_parameters", 0)
      assert Jason.decode!(reply_json) == %{"message_id" => 5}

      {"rich_message", rich_json} = List.keyfind(parts, "rich_message", 0)

      assert %{
               "blocks" => [
                 %{
                   "type" => "collage",
                   "blocks" => [
                     %{"photo" => %{"media" => "attach://file0"}},
                     %{"photo" => %{"media" => "CACHED_FILE_ID"}}
                   ]
                 },
                 %{"video" => %{"media" => "attach://file1"}}
               ]
             } = Jason.decode!(rich_json)
    end

    test "posts through the ExGram adapter, test environment included" do
      adapter = Application.get_env(:ex_gram, :adapter)
      test_environment = Application.get_env(:ex_gram, :test_environment)
      token = Application.fetch_env!(:lolek, :bot_token)
      Application.put_env(:ex_gram, :adapter, Lolek.TelegramTest.PathAdapter)

      on_exit(fn ->
        Application.put_env(:ex_gram, :adapter, adapter)
        restore_ex_gram_env(:test_environment, test_environment)
      end)

      rich_message = %ExGram.Model.InputRichMessage{
        blocks: [photo_block({:file_content, "photo bytes", "a.jpg"})]
      }

      Application.put_env(:ex_gram, :test_environment, false)

      assert {:ok, %ExGram.Model.Message{message_id: 1}} =
               Lolek.ExGramTelegram.send_rich_message(42, rich_message, [])

      assert_receive {:adapter_request, path}
      assert path == "/bot#{token}/sendRichMessage"

      Application.put_env(:ex_gram, :test_environment, true)
      Lolek.ExGramTelegram.send_rich_message(42, rich_message, [])
      assert_receive {:adapter_request, test_path}
      assert test_path == "/bot#{token}/test/sendRichMessage"
    end

    test "leaves messages without local files to ExGram" do
      rich_message = %ExGram.Model.InputRichMessage{blocks: [photo_block("file:///srv/a.jpg")]}

      assert Lolek.ExGramTelegram.rich_message_multipart(42, rich_message, []) == :no_files
    end
  end

  defp photo_block(media) do
    %ExGram.Model.InputRichBlockPhoto{
      type: "photo",
      photo: %ExGram.Model.InputMediaPhoto{type: "photo", media: media}
    }
  end

  defp restore_ex_gram_env(key, nil), do: Application.delete_env(:ex_gram, key)
  defp restore_ex_gram_env(key, value), do: Application.put_env(:ex_gram, key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:lolek, key)
  defp restore_app_env(key, value), do: Application.put_env(:lolek, key, value)
end
