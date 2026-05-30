defmodule Lolek.Telegram do
  @moduledoc """
  Wraps Telegram API calls so sending can be tested without a real Telegram server.
  """

  @callback send_video(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback send_document(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback edit_message_caption(integer(), integer(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @spec send_video(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_video(chat_id, video, options) do
    client().send_video(chat_id, video, options)
  end

  @spec send_document(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_document(chat_id, document, options) do
    client().send_document(chat_id, document, options)
  end

  @spec edit_message_caption(integer(), integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def edit_message_caption(chat_id, message_id, options) do
    client().edit_message_caption(chat_id, message_id, options)
  end

  @spec client() :: module()
  defp client do
    Application.get_env(:lolek, :telegram_client, Lolek.ExGramTelegram)
  end
end
