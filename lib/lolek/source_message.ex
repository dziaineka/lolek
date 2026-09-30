defmodule Lolek.SourceMessage do
  @moduledoc """
  Decides what happens to the message that carried a link: nothing, a reply to
  it, or its deletion once the post is sent.
  """

  require Logger

  @type mode :: :raw | :reply | :delete

  @doc """
  Returns the mode for one request. In the delete mode a request with text
  besides the link is replied to instead, so the sender's words are not lost.
  """
  @spec mode(String.t(), String.t()) :: mode()
  def mode(text, url) do
    case Application.fetch_env!(:lolek, :source_message_mode) do
      :delete -> if String.trim(text) == url, do: :delete, else: :reply
      mode -> mode
    end
  end

  @doc """
  Deletes the request after its post was sent in the delete mode. The post is
  already in the chat, so a failed deletion (no admin rights in a group, the
  message is already gone) only logs a warning.
  """
  @spec finish(mode(), integer(), integer()) :: :ok
  def finish(:delete, chat_id, message_id) do
    case delete_message(chat_id, message_id) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not delete the request message in chat #{chat_id}; reason: #{inspect(reason)}"
        )
    end

    :ok
  end

  def finish(_mode, _chat_id, _message_id), do: :ok

  @spec delete_message(integer(), integer()) :: {:ok, term()} | {:error, term()}
  defp delete_message(chat_id, message_id) do
    Lolek.Telegram.delete_message(chat_id, message_id)
  rescue
    error in ExGram.Error -> {:error, error}
  end
end
