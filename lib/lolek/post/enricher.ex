defmodule Lolek.Post.Enricher do
  @moduledoc """
  Adds linked posts that the first metadata source does not give, like the quoted post
  and the parent post of a tweet.
  """

  @tweet_id ~r{/status(?:es)?/(\d+)}

  require Logger

  @doc """
  Fetches the quoted post and the parent post of a tweet with gallery-dl, one time per
  post. Other posts are returned without a change. A failed fetch keeps the post.
  """
  @spec enrich(Lolek.Post.t()) :: Lolek.Post.t()
  def enrich(%Lolek.Post{platform: :twitter} = post) do
    if needs_enrichment?(post) do
      case enrich_quoted(post) do
        {:ok, post} -> post |> enrich_reply_to() |> mark_enriched()
        # A failed fetch is tried again with the next request.
        {:error, post} -> enrich_reply_to(post)
      end
    else
      post
    end
  end

  def enrich(%Lolek.Post{} = post), do: post

  @doc "Returns true when `enrich/1` has linked posts to look for."
  @spec needs_enrichment?(Lolek.Post.t()) :: boolean()
  def needs_enrichment?(%Lolek.Post{platform: :twitter, extra: extra}) do
    Application.fetch_env!(:lolek, :gallery_download_enabled) and
      not Map.has_key?(extra, :linked_posts)
  end

  def needs_enrichment?(%Lolek.Post{}), do: false

  @spec mark_enriched(Lolek.Post.t()) :: Lolek.Post.t()
  defp mark_enriched(post), do: %{post | extra: Map.put(post.extra, :linked_posts, "fetched")}

  # gallery-dl gives the quoted tweet only with the "quoted" option. The tweet data
  # does not tell if the tweet quotes another tweet, so the tweet is read again.
  @spec enrich_quoted(Lolek.Post.t()) :: {:ok | :error, Lolek.Post.t()}
  defp enrich_quoted(%Lolek.Post{quoted: nil} = post) do
    with tweet_id when is_binary(tweet_id) <- tweet_id(post.url),
         {:ok, fetched} <- fetch_tweet(tweet_id, ["extractor.twitter.quoted=true"]) do
      {:ok, %{post | quoted: fetched.quoted}}
    else
      nil -> {:ok, post}
      :error -> {:error, post}
    end
  end

  defp enrich_quoted(post), do: {:ok, post}

  @spec enrich_reply_to(Lolek.Post.t()) :: Lolek.Post.t()
  defp enrich_reply_to(
         %Lolek.Post{reply_to: %Lolek.Post{text: nil} = ref, extra: %{reply_id: id}} = post
       ) do
    case fetch_tweet(id, []) do
      {:ok, parent} -> %{post | reply_to: Lolek.Post.merge(%{parent | quoted: nil}, ref)}
      :error -> post
    end
  end

  defp enrich_reply_to(post), do: post

  @spec tweet_id(String.t() | nil) :: String.t() | nil
  defp tweet_id(nil), do: nil

  defp tweet_id(url) do
    case Regex.run(@tweet_id, url) do
      [_, id] -> id
      _ -> nil
    end
  end

  @spec fetch_tweet(String.t(), [String.t()]) :: {:ok, Lolek.Post.t()} | :error
  defp fetch_tweet(tweet_id, options) do
    with {:ok, messages} <-
           Lolek.GalleryDownloader.fetch_metadata("https://x.com/i/status/#{tweet_id}", options),
         {:ok, post} <- Lolek.Post.GalleryDl.parse_messages(messages) do
      {:ok, post}
    else
      {:error, reason} ->
        Logger.info("Could not fetch tweet #{tweet_id}; reason: #{inspect(reason)}")
        :error
    end
  end
end
