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
  def send_document(chat_id, document, options) do
    ExGram.send_document(chat_id, document, options)
  end

  @impl true
  def send_photo(chat_id, photo, options) do
    ExGram.send_photo(chat_id, photo, options)
  end

  @impl true
  def send_animation(chat_id, animation, options) do
    ExGram.send_animation(chat_id, animation, options)
  end

  @impl true
  def send_media_group(chat_id, media, options) do
    ExGram.send_media_group(chat_id, media, options)
  end

  @impl true
  def edit_message_caption(chat_id, message_id, options) do
    ExGram.edit_message_caption(options ++ [chat_id: chat_id, message_id: message_id])
  end
end
