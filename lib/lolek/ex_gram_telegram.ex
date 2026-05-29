defmodule Lolek.ExGramTelegram do
  @moduledoc """
  Sends Telegram API requests through ExGram.
  """

  @behaviour Lolek.Telegram

  @impl true
  def send_video(chat_id, video, options) do
    ExGram.send_video(chat_id, video, options)
  end

  @impl true
  def send_document(chat_id, document) do
    ExGram.send_document(chat_id, document)
  end
end
