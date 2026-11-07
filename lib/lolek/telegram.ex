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
