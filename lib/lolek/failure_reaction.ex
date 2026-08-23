defmodule Lolek.FailureReaction do
  @moduledoc """
  Adds opt-in, best-effort Telegram reactions for media processing failures.
  """

  require Logger

  @too_big_media_emoji "🐳"
  @chat_rate_limited_emoji "🥱"
  @processing_deadline_exceeded_emoji "😴"
  @unexpected_error_emoji "😢"

  @doc "Reacts to a failed media request when failure reactions are enabled."
  @spec react(integer(), integer(), term()) :: :ok
  def react(chat_id, message_id, reason) do
    if Application.fetch_env!(:lolek, :failure_reactions_enabled) do
      do_react(chat_id, message_id, reaction_emoji(reason))
    else
      :ok
    end
  end

  @spec do_react(integer(), integer(), String.t()) :: :ok
  defp do_react(chat_id, message_id, emoji) do
    reaction = [%ExGram.Model.ReactionTypeEmoji{type: "emoji", emoji: emoji}]

    case Lolek.Telegram.set_message_reaction(chat_id, message_id,
           reaction: reaction,
           is_big: true
         ) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        log_failure(chat_id, message_id, reason)
    end
  rescue
    exception ->
      log_failure(chat_id, message_id, exception)
  catch
    kind, reason ->
      log_failure(chat_id, message_id, {kind, reason})
  end

  @spec reaction_emoji(term()) :: String.t()
  defp reaction_emoji(:too_big_media), do: @too_big_media_emoji
  defp reaction_emoji(:chat_rate_limited), do: @chat_rate_limited_emoji

  defp reaction_emoji(:processing_deadline_exceeded),
    do: @processing_deadline_exceeded_emoji

  defp reaction_emoji(_reason), do: @unexpected_error_emoji

  @spec log_failure(integer(), integer(), term()) :: :ok
  defp log_failure(chat_id, message_id, reason) do
    Logger.warning(
      "Could not react to failed Telegram message in chat #{chat_id}; " <>
        "message_id=#{message_id}; reason=#{inspect(reason)}"
    )
  end
end
