defmodule Lolek.Telegram do
  @moduledoc """
  Wraps Telegram API calls so sending can be tested without a real Telegram server.
  """

  @callback send_rich_message(integer(), ExGram.Model.InputRichMessage.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback edit_message_text(integer(), integer(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback set_message_reaction(integer(), integer(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback edit_message_reply_markup(integer(), integer(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback send_video(integer(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback send_photo(integer(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback send_media_group(integer(), [struct()], keyword()) :: {:ok, term()} | {:error, term()}
  @callback delete_message(integer(), integer()) :: {:ok, term()} | {:error, term()}

  @doc "Sends photos and videos as a Telegram album."
  @spec send_media_group(integer(), [struct()], keyword()) :: {:ok, term()} | {:error, term()}
  def send_media_group(chat_id, media, options) do
    client().send_media_group(chat_id, media, options)
  end

  @doc "Deletes a message from a chat."
  @spec delete_message(integer(), integer()) :: {:ok, term()} | {:error, term()}
  def delete_message(chat_id, message_id) do
    client().delete_message(chat_id, message_id)
  end

  @doc "Sends a photo using its Telegram file ID."
  @spec send_photo(integer(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_photo(chat_id, file_id, options) do
    client().send_photo(chat_id, file_id, options)
  end

  @doc "Sends a video using its Telegram file ID."
  @spec send_video(integer(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_video(chat_id, file_id, options) do
    client().send_video(chat_id, file_id, options)
  end

  @doc "Updates the buttons on a previously sent message."
  @spec edit_message_reply_markup(integer(), integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def edit_message_reply_markup(chat_id, message_id, options) do
    client().edit_message_reply_markup(chat_id, message_id, options)
  end

  @doc "Sends a rich message to the given chat."
  @spec send_rich_message(integer(), ExGram.Model.InputRichMessage.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_rich_message(chat_id, rich_message, options) do
    client().send_rich_message(chat_id, rich_message, options)
  end

  @doc "Edits the text or the rich content of a previously sent message."
  @spec edit_message_text(integer(), integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def edit_message_text(chat_id, message_id, options) do
    client().edit_message_text(chat_id, message_id, options)
  end

  @doc "Sets the bot's reaction on a message."
  @spec set_message_reaction(integer(), integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def set_message_reaction(chat_id, message_id, options) do
    client().set_message_reaction(chat_id, message_id, options)
  end

  @spec client() :: module()
  defp client do
    Application.get_env(:lolek, :telegram_client, Lolek.ExGramTelegram)
  end
end
