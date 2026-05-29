defmodule Lolek.SendFileTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc false

    @behaviour Lolek.Telegram

    @impl true
    def send_video(_chat_id, _video, _options) do
      Application.fetch_env!(:lolek, :telegram_test_result)
    end

    @impl true
    def send_document(_chat_id, _document) do
      Application.fetch_env!(:lolek, :telegram_test_result)
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
      file_path = "/tmp/downloaded.txt"

      response = %ExGram.Model.Message{
        document: %ExGram.Model.Document{file_id: "telegram-file-id"}
      }

      Application.put_env(:lolek, :telegram_client, TelegramClient)
      Application.put_env(:lolek, :telegram_test_result, {:ok, response})

      assert {:ok, {:sent_to_telegram_at_first, ^file_path, "telegram-file-id"}} =
               Lolek.send_file(123, {:compressed, file_path})
    end)
  end

  defp preserve_telegram_env(fun) do
    client = Application.fetch_env(:lolek, :telegram_client)
    result = Application.fetch_env(:lolek, :telegram_test_result)
    error = Application.fetch_env(:lolek, :telegram_test_error)

    try do
      fun.()
    after
      restore_app_env(:telegram_client, client)
      restore_app_env(:telegram_test_result, result)
      restore_app_env(:telegram_test_error, error)
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
  def send_document(_chat_id, _document) do
    raise Application.fetch_env!(:lolek, :telegram_test_error)
  end
end
