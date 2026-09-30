defmodule Lolek.PostOptions do
  @moduledoc """
  Builds the parts of a post that depend on the request: the reply to it, the
  button to the source and the requester mention.
  """

  # Telegram answered "reply markup is too long" to a 10000-byte button URL
  # and took 8192 bytes intact (checked on the test environment).
  @max_button_url_bytes 8192

  @doc """
  Replies to the request in the reply mode. allow_sending_without_reply keeps
  the post when the request is deleted while the media is still downloading.
  """
  @spec add_reply(keyword(), keyword()) :: keyword()
  def add_reply(options, context) do
    with :reply <- Keyword.get(context, :source_message_mode),
         message_id when is_integer(message_id) <- Keyword.get(context, :source_message_id) do
      Keyword.put(options, :reply_parameters, %ExGram.Model.ReplyParameters{
        message_id: message_id,
        allow_sending_without_reply: true
      })
    else
      _ -> options
    end
  end

  @doc """
  Adds the button to the source post. Telegram rejects the whole message over
  an invalid button URL, so a link it could refuse goes without the button
  rather than failing the post.
  """
  @spec add_source_button(keyword(), keyword()) :: keyword()
  def add_source_button(options, context) do
    url = Keyword.get(context, :source_url)

    if button_url?(url) do
      Keyword.put(options, :reply_markup, %ExGram.Model.InlineKeyboardMarkup{
        inline_keyboard: [[%ExGram.Model.InlineKeyboardButton{text: "Original", url: url}]]
      })
    else
      options
    end
  end

  @doc """
  Returns the requester mention when the post shows who asked, `nil` otherwise.
  A reply already points at the requester, and a deleted request leaves the
  post as the only trace of who asked.
  """
  @spec requester_mention(keyword()) :: ExGram.Model.RichTextTextMention.t() | String.t() | nil
  def requester_mention(context) do
    if Keyword.has_key?(context, :requester) and show_requester?(context) do
      Lolek.Requester.mention(Keyword.get(context, :requester))
    end
  end

  @spec show_requester?(keyword()) :: boolean()
  defp show_requester?(context) do
    case Keyword.get(context, :source_message_mode, :raw) do
      :reply -> false
      :delete -> true
      :raw -> Application.fetch_env!(:lolek, :post_requester_caption)
    end
  end

  @spec button_url?(term()) :: boolean()
  defp button_url?(url) when is_binary(url) and byte_size(url) <= @max_button_url_bytes do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp button_url?(_url), do: false
end
