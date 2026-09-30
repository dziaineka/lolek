defmodule Lolek.SourceMessageTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  defmodule TelegramClient do
    @moduledoc false

    @spec delete_message(integer(), integer()) :: {:ok, true} | {:error, term()}
    def delete_message(chat_id, message_id) do
      send(
        Application.fetch_env!(:lolek, :telegram_test_parent),
        {:delete_message, chat_id, message_id}
      )

      Application.fetch_env!(:lolek, :telegram_test_result)
    end
  end

  @url "https://www.instagram.com/p/abc/"

  setup do
    saved =
      for key <- [
            :source_message_mode,
            :telegram_client,
            :telegram_test_parent,
            :telegram_test_result
          ],
          do: {key, Application.fetch_env(:lolek, key)}

    Application.put_env(:lolek, :telegram_client, TelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())
    Application.put_env(:lolek, :telegram_test_result, {:ok, true})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)
    end)
  end

  describe "mode/2" do
    test "keeps raw and reply as configured" do
      Application.put_env(:lolek, :source_message_mode, :raw)
      assert Lolek.SourceMessage.mode("look #{@url}", @url) == :raw

      Application.put_env(:lolek, :source_message_mode, :reply)
      assert Lolek.SourceMessage.mode(@url, @url) == :reply
    end

    test "deletes a request that is only the link" do
      Application.put_env(:lolek, :source_message_mode, :delete)

      assert Lolek.SourceMessage.mode(" #{@url}\n", @url) == :delete
    end

    test "replies instead of deleting a request with other text" do
      Application.put_env(:lolek, :source_message_mode, :delete)

      assert Lolek.SourceMessage.mode("look at this #{@url}", @url) == :reply
    end
  end

  describe "finish/3" do
    test "deletes the request in the delete mode" do
      assert :ok = Lolek.SourceMessage.finish(:delete, 1, 42)
      assert_receive {:delete_message, 1, 42}
    end

    test "leaves the request alone in other modes" do
      assert :ok = Lolek.SourceMessage.finish(:reply, 1, 42)
      assert :ok = Lolek.SourceMessage.finish(:raw, 1, 42)
      refute_receive {:delete_message, _, _}
    end

    test "only warns when the request cannot be deleted" do
      error = %ExGram.Error{code: 400, message: "Bad Request: message can't be deleted"}
      Application.put_env(:lolek, :telegram_test_result, {:error, error})

      log = capture_log(fn -> assert :ok = Lolek.SourceMessage.finish(:delete, 1, 42) end)

      assert log =~ "Could not delete the request message in chat 1"
    end
  end
end
