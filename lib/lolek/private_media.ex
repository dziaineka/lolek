defmodule Lolek.PrivateMedia do
  @moduledoc """
  Links posts to captionless copies of their media in the bot's private chat.
  Link records live in the download cache and survive restarts until cache eviction.
  """

  require Logger

  @doc "Adds a private-chat link when the post has media and a bot username is provided."
  @spec attach(integer(), integer(), [Lolek.File.sent_media_entry()], String.t() | nil) :: :ok
  def attach(chat_id, message_id, entries, username) when is_binary(username) do
    media =
      for {ext, id} <- entries do
        type = if Lolek.GalleryDownloader.video_file?("x#{ext}"), do: "video", else: "photo"
        %{"type" => type, "id" => id}
      end

    case media do
      [] ->
        :ok

      entries ->
        attach_link(chat_id, message_id, entries, username)
    end
  end

  def attach(_chat_id, _message_id, _entries, _username), do: :ok

  @doc "Sends captionless media in post order, grouping galleries into albums."
  @spec deliver(integer(), String.t()) :: :ok | {:error, term()}
  def deliver(chat_id, token) do
    with {:ok, media} <- read_link(token) do
      deliver_media(chat_id, media)
    end
  end

  @spec deliver_media(integer(), [map()]) :: :ok | {:error, term()}
  defp deliver_media(_chat_id, []), do: :ok

  defp deliver_media(chat_id, [media]) do
    with {:ok, _message} <- send_media(chat_id, media), do: :ok
  end

  defp deliver_media(chat_id, media) do
    # Telegram albums need 2–10 items. Split a final eleven into nine and two.
    batch_size = if length(media) == 11, do: 9, else: 10
    {batch, rest} = Enum.split(media, batch_size)
    album = Enum.map(batch, &album_item/1)

    with {:ok, _messages} <- Lolek.Telegram.send_media_group(chat_id, album, []) do
      deliver_media(chat_id, rest)
    end
  end

  defp album_item(%{"type" => "video", "id" => id}) do
    %ExGram.Model.InputMediaVideo{type: "video", media: id}
  end

  defp album_item(%{"type" => "photo", "id" => id}) do
    %ExGram.Model.InputMediaPhoto{type: "photo", media: id}
  end

  defp send_media(chat_id, %{"type" => "video", "id" => id}) do
    Lolek.Telegram.send_video(chat_id, id, [])
  end

  defp send_media(chat_id, %{"type" => "photo", "id" => id}) do
    Lolek.Telegram.send_photo(chat_id, id, [])
  end

  @spec attach_link(integer(), integer(), [map()], String.t()) :: :ok
  defp attach_link(chat_id, message_id, media, username) do
    with {:ok, token} <- store_link(media),
         button = %ExGram.Model.InlineKeyboardButton{
           text: "Get media privately",
           url: "https://t.me/#{username}?start=media_#{token}"
         },
         markup = %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: [[button]]},
         {:ok, _message} <-
           Lolek.Telegram.edit_message_reply_markup(chat_id, message_id, reply_markup: markup) do
      :ok
    else
      {:error, reason} ->
        log_link_failure(reason)
    end
  rescue
    error ->
      log_link_failure(error)
  end

  @spec store_link([map()]) :: {:ok, String.t()} | {:error, term()}
  defp store_link(media) do
    # Telegram keeps file IDs usable, but a bot link allows only 64 characters
    # for our data. We cannot reliably fit a gallery's IDs, so we save them under
    # a random key. The link expires when cache cleanup removes that record.
    # Link limit: https://core.telegram.org/bots/features#deep-linking
    # File IDs: https://core.telegram.org/bots/faq#can-i-count-on-file-ids-to-be-persistent
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    path = link_path(token)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(media), [:exclusive]) do
      {:ok, token}
    end
  end

  @spec read_link(String.t()) :: {:ok, [map()]} | {:error, :expired_link}
  defp read_link(token) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, token),
         {:ok, json} <- File.read(link_path(token)),
         {:ok, [_ | _] = media} <- Jason.decode(json),
         true <- Enum.all?(media, &valid_media?/1) do
      {:ok, media}
    else
      _ ->
        {:error, :expired_link}
    end
  end

  defp valid_media?(%{"type" => type, "id" => id}) do
    type in ["video", "photo"] and is_binary(id) and id != ""
  end

  defp valid_media?(_media), do: false

  @spec link_path(String.t()) :: String.t()
  defp link_path(token) do
    Path.join([
      Application.fetch_env!(:lolek, :download_path),
      "private-media-#{token}",
      "media.json"
    ])
  end

  @spec log_link_failure(term()) :: :ok
  defp log_link_failure(reason) do
    Logger.warning("Could not attach private media link: #{inspect(reason)}")
  end
end
