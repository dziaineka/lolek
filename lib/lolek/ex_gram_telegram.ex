defmodule Lolek.ExGramTelegram do
  @moduledoc """
  Sends Telegram API requests through ExGram.
  """

  @behaviour Lolek.Telegram

  @impl true
  def send_rich_message(chat_id, rich_message, options) do
    ExGram.send_rich_message(chat_id, rich_message, options)
  end

  @impl true
  def edit_message_text(chat_id, message_id, options) do
    ExGram.edit_message_text(options ++ [chat_id: chat_id, message_id: message_id])
  end

  @impl true
  def set_message_reaction(chat_id, message_id, options) do
    ExGram.set_message_reaction(chat_id, message_id, options)
  end
end
