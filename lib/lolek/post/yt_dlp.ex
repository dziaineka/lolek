defmodule Lolek.Post.YtDlp do
  @moduledoc """
  Builds a `Lolek.Post` from the yt-dlp `--dump-single-json` output.
  """

  @platforms %{
    "twitter" => :twitter,
    "bluesky" => :bluesky,
    "tiktok" => :tiktok,
    "instagram" => :instagram,
    "facebook" => :facebook,
    "youtube" => :youtube,
    "coub" => :coub,
    "threads" => :threads
  }

  @doc "Builds a post from yt-dlp metadata."
  @spec parse(map(), String.t() | nil) :: Lolek.Post.t()
  def parse(metadata, url \\ nil) when is_map(metadata) do
    platform = platform(metadata, url)
    reply? = platform == :twitter and String.starts_with?(get(metadata, "description") || "", "@")
    text = get(metadata, "description") || get(metadata, "title")

    %Lolek.Post{
      platform: platform,
      source: :yt_dlp,
      url: get(metadata, "webpage_url") || url,
      title: title(metadata),
      author: author(platform, metadata),
      text: Lolek.Post.Text.clean(text, platform, reply?: reply?),
      published_at:
        Lolek.Post.parse_datetime(metadata["timestamp"]) ||
          Lolek.Post.parse_datetime(metadata["upload_date"]),
      stats:
        Lolek.Post.stats(
          likes: metadata["like_count"],
          reposts: metadata["repost_count"],
          replies: metadata["comment_count"],
          views: metadata["view_count"]
        ),
      extra: Lolek.Post.extra(music: music(metadata), location: get(metadata, "location"))
    }
  end

  @spec platform(map(), String.t() | nil) :: Lolek.Post.platform()
  defp platform(metadata, url) do
    key =
      (get(metadata, "extractor_key") || get(metadata, "extractor") || "") |> String.downcase()

    Enum.find_value(@platforms, fn {prefix, platform} ->
      if String.starts_with?(key, prefix), do: platform
    end) || Lolek.Post.platform_from_url(get(metadata, "webpage_url") || url)
  end

  @spec title(map()) :: String.t() | nil
  defp title(metadata) do
    Enum.find_value(["title", "fulltitle", "alt_title"], &get(metadata, &1))
  end

  # yt-dlp keeps the display name and the handle in different fields per site.
  @spec author(Lolek.Post.platform(), map()) :: Lolek.Post.author() | nil
  defp author(:tiktok, metadata) do
    Lolek.Post.author(
      get(metadata, "channel"),
      get(metadata, "uploader"),
      get(metadata, "uploader_url"),
      metadata["channel_is_verified"]
    )
  end

  defp author(:instagram, metadata) do
    Lolek.Post.author(
      get(metadata, "uploader"),
      get(metadata, "channel"),
      get(metadata, "uploader_url") || profile_url(:instagram, get(metadata, "channel")),
      metadata["channel_is_verified"]
    )
  end

  defp author(platform, metadata) do
    Lolek.Post.author(
      get(metadata, "uploader") || get(metadata, "channel") || get(metadata, "creator"),
      handle(get(metadata, "uploader_id")),
      profile_url(platform, metadata),
      metadata["channel_is_verified"]
    )
  end

  @spec profile_url(Lolek.Post.platform(), map() | String.t() | nil) :: String.t() | nil
  defp profile_url(:instagram, handle) when is_binary(handle),
    do: "https://www.instagram.com/#{handle}/"

  defp profile_url(:twitter, %{} = metadata) do
    case handle(get(metadata, "uploader_id")) do
      nil -> get(metadata, "uploader_url")
      handle -> "https://x.com/#{handle}"
    end
  end

  defp profile_url(_platform, %{} = metadata),
    do: get(metadata, "uploader_url") || get(metadata, "channel_url")

  defp profile_url(_platform, _value), do: nil

  # Numeric ids are not handles that people know.
  @spec handle(String.t() | nil) :: String.t() | nil
  defp handle(nil), do: nil

  defp handle(value) do
    if String.match?(value, ~r/\A\d+\z/), do: nil, else: value
  end

  @spec music(map()) :: String.t() | nil
  defp music(metadata) do
    track = get(metadata, "track")

    artist =
      case metadata["artists"] do
        [first | _] when is_binary(first) -> first
        _ -> get(metadata, "artist")
      end

    case {track, artist} do
      {nil, _artist} -> nil
      {track, nil} -> track
      {track, artist} -> "#{track} – #{artist}"
    end
  end

  @spec get(map(), String.t()) :: String.t() | nil
  defp get(metadata, key), do: Lolek.Post.blank_to_nil(metadata[key])
end
