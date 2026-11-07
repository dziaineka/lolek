defmodule Lolek.Post.GalleryDl do
  @moduledoc """
  Builds a `Lolek.Post` from gallery-dl metadata (`--dump-json` output or `info.json` files).
  """

  @doc """
  Builds a post from the messages of `gallery-dl --dump-json`. The post metadata comes
  from the first directory message (type 2) or, when there is none, from the first
  media message (type 3). Photo URLs of the media messages become `media` of the post.

  With the `extractor.twitter.quoted` option, gallery-dl also gives the quoted tweet.
  Its `quote_id` is the id of the tweet that quotes it, so it becomes `quoted`.
  """
  @spec parse_messages(term()) :: {:ok, Lolek.Post.t()} | {:error, :no_post_metadata}
  def parse_messages(messages) when is_list(messages) do
    metadata =
      Enum.find_value(messages, &directory_metadata/1) ||
        Enum.find_value(messages, &media_metadata/1)

    case metadata && parse(metadata) do
      %Lolek.Post{} = post ->
        {own, others} = split_by_tweet(messages, metadata["tweet_id"])
        {:ok, %{post | media: photo_urls(own), quoted: quoted(others, metadata)}}

      _ ->
        {:error, :no_post_metadata}
    end
  end

  def parse_messages(_messages), do: {:error, :no_post_metadata}

  # Other sites have no "tweet_id", so all messages belong to the post.
  @spec split_by_tweet([term()], term()) :: {[term()], [term()]}
  defp split_by_tweet(messages, nil), do: {messages, []}

  defp split_by_tweet(messages, tweet_id) do
    Enum.split_with(messages, fn message ->
      case List.last(List.wrap(message)) do
        %{"tweet_id" => id} -> id == tweet_id
        _ -> true
      end
    end)
  end

  @spec quoted([term()], map()) :: Lolek.Post.t() | nil
  defp quoted(_messages, %{"tweet_id" => nil}), do: nil

  defp quoted(messages, %{"tweet_id" => tweet_id}) do
    quoted_messages =
      Enum.filter(messages, fn message ->
        match?(%{"quote_id" => ^tweet_id}, List.last(List.wrap(message)))
      end)

    case quoted_messages do
      [] ->
        nil

      quoted_messages ->
        case parse_messages(quoted_messages) do
          {:ok, quoted} -> quoted
          {:error, _reason} -> nil
        end
    end
  end

  defp quoted(_messages, _metadata), do: nil

  @spec directory_metadata(term()) :: map() | nil
  defp directory_metadata([2, %{} = metadata]), do: metadata
  defp directory_metadata(_message), do: nil

  @spec media_metadata(term()) :: map() | nil
  defp media_metadata([3, _url, %{} = metadata]), do: metadata
  defp media_metadata(_message), do: nil

  @spec photo_urls([term()]) :: [Lolek.Post.remote_media()]
  defp photo_urls(messages) do
    Enum.flat_map(messages, fn
      [3, url, %{"extension" => ext}] when is_binary(url) and ext in ~w(jpg jpeg png webp) ->
        [%{type: :photo, url: url}]

      _ ->
        []
    end)
  end

  @doc "Builds a post from one gallery-dl metadata map. Returns nil when the map has no post data."
  @spec parse(map()) :: Lolek.Post.t() | nil
  def parse(%{"category" => "twitter"} = m), do: twitter(m)
  def parse(%{"category" => "bluesky"} = m), do: bluesky(m)
  def parse(%{"category" => "tiktok"} = m), do: tiktok(m)
  def parse(%{"category" => "instagram"} = m), do: instagram(m)
  def parse(%{} = m), do: generic(m)

  @spec twitter(map()) :: Lolek.Post.t()
  defp twitter(m) do
    author = map(m["author"])
    # gallery-dl keeps the screen name in "name" and the display name in "nick".
    handle = str(author["name"])
    reply_id = id(m["reply_id"])

    %Lolek.Post{
      platform: :twitter,
      source: :gallery_dl,
      url: twitter_url(handle, id(m["tweet_id"])),
      author:
        Lolek.Post.author(
          str(author["nick"]),
          handle,
          handle && "https://x.com/#{handle}",
          author["verified"]
        ),
      text: Lolek.Post.Text.clean(m["content"], :twitter, reply?: not is_nil(reply_id)),
      published_at: Lolek.Post.parse_datetime(m["date"]),
      stats:
        Lolek.Post.stats(
          likes: m["favorite_count"],
          reposts: m["retweet_count"],
          replies: m["reply_count"],
          quotes: m["quote_count"],
          views: m["view_count"],
          bookmarks: m["bookmark_count"]
        ),
      reply_to: twitter_reply_to(str(m["reply_to"]), reply_id),
      extra: Lolek.Post.extra(reply_id: reply_id)
    }
  end

  @spec twitter_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp twitter_url(_handle, nil), do: nil
  defp twitter_url(nil, tweet_id), do: "https://x.com/i/status/#{tweet_id}"
  defp twitter_url(handle, tweet_id), do: "https://x.com/#{handle}/status/#{tweet_id}"

  # The parent post is only a reference here. `Lolek.Post.Enricher` can fetch it.
  @spec twitter_reply_to(String.t() | nil, String.t() | nil) :: Lolek.Post.t() | nil
  defp twitter_reply_to(_handle, nil), do: nil

  defp twitter_reply_to(handle, reply_id) do
    %Lolek.Post{
      platform: :twitter,
      source: :gallery_dl,
      url: twitter_url(handle, reply_id),
      author: Lolek.Post.author(nil, handle, handle && "https://x.com/#{handle}")
    }
  end

  @spec bluesky(map()) :: Lolek.Post.t()
  defp bluesky(m) do
    author = map(m["author"])
    handle = str(author["handle"])
    post_id = str(m["post_id"])

    %Lolek.Post{
      platform: :bluesky,
      source: :gallery_dl,
      url: handle && post_id && "https://bsky.app/profile/#{handle}/post/#{post_id}",
      author:
        Lolek.Post.author(
          str(author["displayName"]),
          handle,
          handle && "https://bsky.app/profile/#{handle}",
          get_in(author, ["verification", "verifiedStatus"]) == "valid"
        ),
      text: Lolek.Post.Text.clean(m["text"], :bluesky),
      published_at: Lolek.Post.parse_datetime(m["createdAt"] || m["date"]),
      stats:
        Lolek.Post.stats(
          likes: m["likeCount"],
          reposts: m["repostCount"],
          replies: m["replyCount"],
          quotes: m["quoteCount"],
          bookmarks: m["bookmarkCount"]
        )
    }
  end

  @spec tiktok(map()) :: Lolek.Post.t()
  defp tiktok(m) do
    author = map(m["author"])
    handle = str(author["uniqueId"])
    stats = map(m["statsV2"]) |> Map.merge(map(m["stats"]))
    music = map(m["music"])

    %Lolek.Post{
      platform: :tiktok,
      source: :gallery_dl,
      url: handle && str(m["id"]) && "https://www.tiktok.com/@#{handle}/video/#{m["id"]}",
      author:
        Lolek.Post.author(
          str(author["nickname"]),
          handle,
          handle && "https://www.tiktok.com/@#{handle}",
          author["verified"]
        ),
      text: Lolek.Post.Text.clean(m["desc"], :tiktok),
      published_at: Lolek.Post.parse_datetime(m["createTime"] || m["date"]),
      stats:
        Lolek.Post.stats(
          likes: stats["diggCount"],
          reposts: stats["shareCount"],
          replies: stats["commentCount"],
          views: stats["playCount"],
          bookmarks: stats["collectCount"]
        ),
      extra: Lolek.Post.extra(music: tiktok_music(music))
    }
  end

  @spec tiktok_music(map()) :: String.t() | nil
  defp tiktok_music(music) do
    case {str(music["title"]), str(music["authorName"])} do
      {nil, _author} -> nil
      {title, nil} -> title
      {title, author} -> "#{title} – #{author}"
    end
  end

  @spec instagram(map()) :: Lolek.Post.t()
  defp instagram(m) do
    handle = str(m["username"])

    %Lolek.Post{
      platform: :instagram,
      source: :gallery_dl,
      url: str(m["post_url"]),
      author:
        Lolek.Post.author(
          str(m["fullname"]),
          handle,
          handle && "https://www.instagram.com/#{handle}/"
        ),
      text: Lolek.Post.Text.clean(m["description"], :instagram),
      published_at: Lolek.Post.parse_datetime(m["post_date"] || m["date"]),
      stats: Lolek.Post.stats(likes: m["likes"], replies: m["comments"]),
      extra: Lolek.Post.extra(location: instagram_location(m))
    }
  end

  @spec instagram_location(map()) :: String.t() | nil
  defp instagram_location(%{"location" => %{"name" => name}}), do: str(name)
  defp instagram_location(%{"location" => name}) when is_binary(name), do: str(name)
  defp instagram_location(_m), do: nil

  @spec generic(map()) :: Lolek.Post.t() | nil
  defp generic(m) do
    text = Enum.find_value(["content", "description", "text", "title"], &str(m[&1]))
    platform = category_platform(m["category"])

    post = %Lolek.Post{
      platform: platform,
      source: :gallery_dl,
      text: Lolek.Post.Text.clean(text, platform),
      published_at: Lolek.Post.parse_datetime(m["date"])
    }

    if is_nil(post.text), do: nil, else: post
  end

  @spec category_platform(term()) :: Lolek.Post.platform()
  defp category_platform("facebook"), do: :facebook
  defp category_platform("threads"), do: :threads
  defp category_platform("youtube"), do: :youtube
  defp category_platform(_category), do: :generic

  @spec map(term()) :: map()
  defp map(%{} = value), do: value
  defp map(_value), do: %{}

  @spec str(term()) :: String.t() | nil
  defp str(value), do: Lolek.Post.blank_to_nil(value)

  # gallery-dl uses 0 for "no id".
  @spec id(term()) :: String.t() | nil
  defp id(value) when is_integer(value) and value > 0, do: Integer.to_string(value)
  defp id(value) when is_binary(value) and value not in ["", "0"], do: value
  defp id(_value), do: nil
end
