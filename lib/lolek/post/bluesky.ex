defmodule Lolek.Post.Bluesky do
  @moduledoc """
  Reads Bluesky posts from the public Bluesky AppView API. The API gives the text with
  link facets, the quoted post, the parent post, link cards, and the counters.
  """

  @api_url "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread"
  @max_timeout_ms 15_000
  @post_path ~r{\A/profile/([^/]+)/post/([A-Za-z0-9]+)}

  @doc "Fetches the post of a `bsky.app` post URL."
  @spec fetch(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  def fetch(url) do
    with {:ok, at_uri} <- at_uri(url),
         {:ok, body} <- get_thread(at_uri) do
      parse_thread(body)
    end
  end

  @doc "Converts a `bsky.app` post URL to an AT URI."
  @spec at_uri(String.t()) :: {:ok, String.t()} | {:error, :not_a_bluesky_post}
  def at_uri(url) do
    case Regex.run(@post_path, URI.parse(url).path || "") do
      [_, actor, rkey] -> {:ok, "at://#{actor}/app.bsky.feed.post/#{rkey}"}
      _ -> {:error, :not_a_bluesky_post}
    end
  end

  @spec get_thread(String.t()) :: {:ok, map()} | {:error, term()}
  defp get_thread(at_uri) do
    case Req.get(@api_url,
           params: [uri: at_uri, depth: 0, parentHeight: 1],
           receive_timeout: timeout(),
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:bluesky_api_status, status}}
      {:error, reason} -> {:error, {:bluesky_api, reason}}
    end
  end

  @doc "Builds a post from an `app.bsky.feed.getPostThread` response."
  @spec parse_thread(map()) :: {:ok, Lolek.Post.t()} | {:error, :invalid_bluesky_thread}
  def parse_thread(%{"thread" => %{"post" => %{} = post_view} = thread}) do
    post = %{parse_post_view(post_view) | reply_to: parent(thread["parent"])}
    {:ok, post}
  end

  def parse_thread(_body), do: {:error, :invalid_bluesky_thread}

  @spec parent(term()) :: Lolek.Post.t() | nil
  defp parent(%{"post" => %{} = post_view}), do: parse_post_view(post_view)
  defp parent(_parent), do: nil

  # A post view keeps the record in "record". A quoted record view keeps it in "value"
  # and its embeds in "embeds".
  @spec parse_post_view(map()) :: Lolek.Post.t()
  defp parse_post_view(view) do
    record = map(view["record"] || view["value"])
    embed = view["embed"] || List.first(view["embeds"] || [])
    author = map(view["author"])
    handle = str(author["handle"])
    text = record["text"]

    %Lolek.Post{
      platform: :bluesky,
      source: :api,
      url: post_url(handle || str(author["did"]), view["uri"]),
      author:
        Lolek.Post.author(
          str(author["displayName"]),
          handle,
          handle && "https://bsky.app/profile/#{handle}",
          get_in(author, ["verification", "verifiedStatus"]) == "valid"
        ),
      text: if(is_binary(text) and String.trim(text) != "", do: text),
      facets: facets(record["facets"], text),
      published_at: Lolek.Post.parse_datetime(record["createdAt"]),
      stats:
        Lolek.Post.stats(
          likes: view["likeCount"],
          reposts: view["repostCount"],
          replies: view["replyCount"],
          quotes: view["quoteCount"],
          bookmarks: view["bookmarkCount"]
        ),
      quoted: quoted(embed),
      media: embed_media(embed),
      link_card: link_card(embed)
    }
  end

  @spec post_url(String.t() | nil, term()) :: String.t() | nil
  defp post_url(actor, "at://" <> _ = uri) when is_binary(actor) do
    case String.split(uri, "/") |> List.last() do
      rkey when is_binary(rkey) and rkey != "" -> "https://bsky.app/profile/#{actor}/post/#{rkey}"
      _ -> nil
    end
  end

  defp post_url(_actor, _uri), do: nil

  @spec quoted(term()) :: Lolek.Post.t() | nil
  defp quoted(%{"$type" => "app.bsky.embed.record#view", "record" => record}),
    do: quoted_record(record)

  defp quoted(%{"$type" => "app.bsky.embed.recordWithMedia#view", "record" => %{"record" => r}}),
    do: quoted_record(r)

  defp quoted(_embed), do: nil

  @spec quoted_record(term()) :: Lolek.Post.t() | nil
  defp quoted_record(%{"$type" => "app.bsky.embed.record#viewRecord"} = record),
    do: parse_post_view(record)

  defp quoted_record(_record), do: nil

  @spec embed_media(term()) :: [Lolek.Post.remote_media()]
  defp embed_media(%{"$type" => "app.bsky.embed.images#view", "images" => images})
       when is_list(images) do
    Enum.flat_map(images, fn
      %{"fullsize" => url} when is_binary(url) -> [%{type: :photo, url: url}]
      _ -> []
    end)
  end

  # Telegram cannot fetch HLS playlists, so the video preview image is used.
  defp embed_media(%{"$type" => "app.bsky.embed.video#view", "thumbnail" => url})
       when is_binary(url),
       do: [%{type: :photo, url: url}]

  defp embed_media(%{"$type" => "app.bsky.embed.recordWithMedia#view", "media" => media}),
    do: embed_media(media)

  defp embed_media(_embed), do: []

  @spec link_card(term()) :: Lolek.Post.link_card() | nil
  defp link_card(%{"$type" => "app.bsky.embed.external#view", "external" => %{"uri" => uri} = e})
       when is_binary(uri) do
    %{url: uri, title: str(e["title"]), description: str(e["description"])}
  end

  defp link_card(%{"$type" => "app.bsky.embed.recordWithMedia#view", "media" => media}),
    do: link_card(media)

  defp link_card(_embed), do: nil

  @spec facets(term(), term()) :: [Lolek.Post.facet()] | nil
  defp facets(facets, text) when is_list(facets) and is_binary(text) do
    facets
    |> Enum.flat_map(&facet(&1, text))
    |> Enum.sort_by(& &1.start)
    |> drop_overlaps()
  end

  defp facets(_facets, _text), do: nil

  @spec facet(term(), String.t()) :: [Lolek.Post.facet()]
  defp facet(
         %{"index" => %{"byteStart" => start, "byteEnd" => stop}, "features" => [feature | _]},
         text
       )
       when is_integer(start) and is_integer(stop) and start >= 0 and stop > start do
    with true <- stop <= byte_size(text),
         label = binary_part(text, start, stop - start),
         true <- String.valid?(label),
         {type, value} <- feature_link(feature, label) do
      [%{start: start, stop: stop, type: type, value: value}]
    else
      _ -> []
    end
  end

  defp facet(_facet, _text), do: []

  # A mention links to the handle in the text when it is valid, otherwise to the DID.
  @spec feature_link(term(), String.t()) :: {:link | :mention | :tag, String.t()} | nil
  defp feature_link(%{"$type" => "app.bsky.richtext.facet#link", "uri" => uri}, _label)
       when is_binary(uri),
       do: {:link, uri}

  defp feature_link(%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}, label)
       when is_binary(did) do
    actor =
      case label do
        "@" <> handle -> if String.match?(handle, ~r/\A[A-Za-z0-9.\-]+\z/), do: handle, else: did
        _ -> did
      end

    {:mention, "https://bsky.app/profile/#{actor}"}
  end

  defp feature_link(%{"$type" => "app.bsky.richtext.facet#tag", "tag" => tag}, _label)
       when is_binary(tag),
       do: {:tag, "https://bsky.app/hashtag/#{URI.encode(tag, &URI.char_unreserved?/1)}"}

  defp feature_link(_feature, _label), do: nil

  @spec drop_overlaps([Lolek.Post.facet()]) :: [Lolek.Post.facet()]
  defp drop_overlaps(facets) do
    facets
    |> Enum.reduce({[], 0}, fn facet, {acc, last_stop} ->
      if facet.start >= last_stop, do: {[facet | acc], facet.stop}, else: {acc, last_stop}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec timeout() :: pos_integer()
  defp timeout do
    :lolek
    |> Application.fetch_env!(:download_command_timeout_seconds)
    |> :timer.seconds()
    |> min(@max_timeout_ms)
  end

  @spec map(term()) :: map()
  defp map(%{} = value), do: value
  defp map(_value), do: %{}

  @spec str(term()) :: String.t() | nil
  defp str(value), do: Lolek.Post.blank_to_nil(value)
end
