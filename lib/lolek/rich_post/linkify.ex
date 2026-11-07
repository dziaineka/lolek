defmodule Lolek.RichPost.Linkify do
  @moduledoc """
  Finds URLs, mentions, and hashtags in post text and links them to the source platform.
  """

  @url_regex ~r{https?://[^\s<>"]+}iu
  @mention_regex ~r/(?<![\w@.\/])@([A-Za-z0-9_](?:[A-Za-z0-9_.\-]*[A-Za-z0-9_])?)/u
  @hashtag_regex ~r/(?<![\w#&\/])#(\w*[^\W\d_]\w*)/u
  @url_trailing_punctuation ~r/[.,!?:;'")\]]+\z/u

  @type segment :: {:text, String.t()} | {:link, String.t(), String.t()}

  @doc """
  Splits text into plain and linked segments. The given facets are used when present;
  otherwise the facets are found in the text.
  """
  @spec segments(String.t(), [Lolek.Post.facet()] | nil, Lolek.Post.platform()) :: [segment()]
  def segments(text, nil, platform), do: segments(text, facets(text, platform), platform)

  def segments(text, facets, _platform) do
    {segments, offset} =
      Enum.reduce(facets, {[], 0}, fn facet, {acc, offset} ->
        if facet.start >= offset and facet.stop <= byte_size(text) do
          before = binary_part(text, offset, facet.start - offset)
          label = binary_part(text, facet.start, facet.stop - facet.start)
          {[{:link, label, facet.value}, {:text, before} | acc], facet.stop}
        else
          {acc, offset}
        end
      end)

    rest = binary_part(text, offset, byte_size(text) - offset)

    [{:text, rest} | segments]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == {:text, ""}))
  end

  @doc "Finds URL, mention, and hashtag facets in text. Offsets are in bytes."
  @spec facets(String.t(), Lolek.Post.platform()) :: [Lolek.Post.facet()]
  def facets(text, platform) do
    urls =
      @url_regex
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, length}] ->
        url = binary_part(text, start, length)
        trimmed = String.replace(url, @url_trailing_punctuation, "")
        %{start: start, stop: start + byte_size(trimmed), type: :link, value: trimmed}
      end)

    mentions = named_facets(text, @mention_regex, :mention, &profile_url(platform, &1))
    tags = named_facets(text, @hashtag_regex, :tag, &tag_url(platform, &1))

    (urls ++ mentions ++ tags)
    |> Enum.reject(&(&1.stop <= &1.start))
    |> Enum.sort_by(& &1.start)
    |> drop_overlaps()
  end

  @spec named_facets(String.t(), Regex.t(), :mention | :tag, (String.t() -> String.t() | nil)) ::
          [Lolek.Post.facet()]
  defp named_facets(text, regex, type, url_fun) do
    regex
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{start, length}, {name_start, name_length}] ->
      case url_fun.(binary_part(text, name_start, name_length)) do
        nil -> []
        url -> [%{start: start, stop: start + length, type: type, value: url}]
      end
    end)
  end

  @spec drop_overlaps([Lolek.Post.facet()]) :: [Lolek.Post.facet()]
  defp drop_overlaps(facets) do
    facets
    |> Enum.reduce({[], 0}, fn facet, {acc, last_stop} ->
      if facet.start >= last_stop, do: {[facet | acc], facet.stop}, else: {acc, last_stop}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Returns the profile URL of a handle on the platform."
  @spec profile_url(Lolek.Post.platform(), String.t()) :: String.t() | nil
  def profile_url(:twitter, handle), do: "https://x.com/#{handle}"
  def profile_url(:bluesky, handle), do: "https://bsky.app/profile/#{handle}"
  def profile_url(:threads, handle), do: "https://www.threads.com/@#{handle}"
  def profile_url(:instagram, handle), do: "https://www.instagram.com/#{handle}/"
  def profile_url(:tiktok, handle), do: "https://www.tiktok.com/@#{handle}"
  def profile_url(:youtube, handle), do: "https://www.youtube.com/@#{handle}"
  def profile_url(_platform, _handle), do: nil

  @spec tag_url(Lolek.Post.platform(), String.t()) :: String.t() | nil
  defp tag_url(platform, tag) do
    tag = URI.encode(tag, &URI.char_unreserved?/1)

    case platform do
      :twitter -> "https://x.com/hashtag/#{tag}"
      :bluesky -> "https://bsky.app/hashtag/#{tag}"
      :threads -> "https://www.threads.com/search?q=%23#{tag}&serp_type=tags"
      :instagram -> "https://www.instagram.com/explore/tags/#{tag}/"
      :tiktok -> "https://www.tiktok.com/tag/#{tag}"
      :youtube -> "https://www.youtube.com/hashtag/#{tag}"
      :facebook -> "https://www.facebook.com/hashtag/#{tag}"
      _ -> nil
    end
  end
end
