defmodule Lolek.Post.Threads do
  @moduledoc """
  Builds a `Lolek.Post` from the post data that a Threads post page embeds: author,
  text with links and mentions, counters, quoted post, parent author, and link card.
  """

  # Threads puts this object replacement character in the caption where it shows
  # media or a link card.
  @object_replacement "\u{FFFC}"
  @max_remote_media 4

  @doc """
  Finds the post with the given shortcode in the decoded JSON documents of a page.
  The page has more than one copy of a post; the copy with the author has the most data.
  """
  @spec find_post([term()], String.t()) :: map() | nil
  def find_post(documents, shortcode) do
    documents
    |> collect_posts(shortcode)
    |> Enum.max_by(&map_size/1, fn -> nil end)
  end

  @spec collect_posts(term(), String.t()) :: [map()]
  defp collect_posts(%{"code" => code, "user" => %{"username" => _}} = map, code),
    do: [map | collect_posts(Map.delete(map, "code"), code)]

  defp collect_posts(%{} = map, code),
    do: Enum.flat_map(Map.values(map), &collect_posts(&1, code))

  defp collect_posts(list, code) when is_list(list),
    do: Enum.flat_map(list, &collect_posts(&1, code))

  defp collect_posts(_value, _code), do: []

  @doc "Builds a post from one Threads post object."
  @spec parse(map(), String.t() | nil) :: Lolek.Post.t()
  def parse(node, url \\ nil) when is_map(node) do
    info = map(node["text_post_app_info"])
    user = map(node["user"])
    handle = str(user["username"])
    {text, facets} = text_and_facets(node, info)

    %Lolek.Post{
      platform: :threads,
      source: :page,
      url: post_url(handle, str(node["code"])) || url,
      author: author(handle, str(user["full_name"]), user["is_verified"]),
      text: text,
      facets: facets,
      published_at: Lolek.Post.parse_datetime(node["taken_at"]),
      stats:
        Lolek.Post.stats(
          likes: node["like_count"],
          replies: info["direct_reply_count"],
          reposts: info["repost_count"],
          quotes: info["quote_count"]
        ),
      quoted: quoted(info),
      reply_to: reply_to(info),
      media: photo_urls(node),
      link_card: link_card(info["link_preview_attachment"])
    }
  end

  @spec author(String.t() | nil, String.t() | nil, term()) :: Lolek.Post.author() | nil
  defp author(handle, name, verified) do
    Lolek.Post.author(name, handle, handle && "https://www.threads.com/@#{handle}", verified)
  end

  @spec post_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp post_url(handle, code) when is_binary(handle) and is_binary(code),
    do: "https://www.threads.com/@#{handle}/post/#{code}"

  defp post_url(_handle, _code), do: nil

  # Threads shows a `quoted_attachment_post` (media of another post) as the media of
  # this post, not as a quoted post. The media downloader gets that media.
  @spec quoted(map()) :: Lolek.Post.t() | nil
  defp quoted(info) do
    case get_in(map(info["share_info"]), ["quoted_post"]) do
      %{"user" => %{"username" => _}} = quoted -> parse(quoted)
      _ -> nil
    end
  end

  # The page gives only the author of the parent post.
  @spec reply_to(map()) :: Lolek.Post.t() | nil
  defp reply_to(%{"is_reply" => true, "reply_to_author" => %{"username" => handle}})
       when is_binary(handle) do
    %Lolek.Post{platform: :threads, source: :page, author: author(handle, nil, false)}
  end

  defp reply_to(_info), do: nil

  @spec link_card(term()) :: Lolek.Post.link_card() | nil
  defp link_card(%{"url" => url} = card) when is_binary(url) do
    %{url: url, title: str(card["title"]), description: str(card["display_url"])}
  end

  defp link_card(_card), do: nil

  # The photos of a post, used when the post is shown inside another post.
  @spec photo_urls(map()) :: [Lolek.Post.remote_media()]
  defp photo_urls(node) do
    items =
      case node["carousel_media"] do
        [_ | _] = carousel -> carousel
        _ -> [node]
      end

    items
    |> Enum.flat_map(fn
      %{"image_versions2" => %{"candidates" => [%{"url" => url} | _]}} when is_binary(url) ->
        [%{type: :photo, url: url}]

      _ ->
        []
    end)
    |> Enum.take(@max_remote_media)
  end

  # The text fragments give the links and the mentions. Without them, the caption
  # is the plain text.
  @spec text_and_facets(map(), map()) :: {String.t() | nil, [Lolek.Post.facet()] | nil}
  defp text_and_facets(node, info) do
    case get_in(info, ["text_fragments", "fragments"]) do
      [_ | _] = fragments -> from_fragments(fragments)
      _ -> {clean(get_in(map(node["caption"]), ["text"])), nil}
    end
  end

  @spec from_fragments([term()]) :: {String.t() | nil, [Lolek.Post.facet()] | nil}
  defp from_fragments(fragments) do
    {text, facets} =
      Enum.reduce(fragments, {"", []}, fn fragment, {text, facets} ->
        label =
          fragment |> map() |> Map.get("plaintext") |> then(&if(is_binary(&1), do: &1, else: ""))

        facets =
          case fragment_link(map(fragment)) do
            {type, value} when label != "" ->
              start = byte_size(text)
              [%{start: start, stop: start + byte_size(label), type: type, value: value} | facets]

            _ ->
              facets
          end

        {text <> label, facets}
      end)

    text = String.replace(text, @object_replacement, "")
    trimmed = String.trim_leading(text)
    shift = byte_size(text) - byte_size(trimmed)
    trimmed = String.trim_trailing(trimmed)

    facets =
      facets
      |> Enum.reverse()
      |> Enum.map(&%{&1 | start: &1.start - shift, stop: &1.stop - shift})
      |> Enum.filter(&(&1.start >= 0 and &1.stop <= byte_size(trimmed)))

    case {trimmed, facets} do
      {"", _facets} -> {nil, nil}
      # Without marked links, Lolek.RichPost.Linkify finds the URLs and hashtags.
      {text, []} -> {text, nil}
      {text, facets} -> {text, facets}
    end
  end

  @spec fragment_link(map()) :: {:link | :mention, String.t()} | nil
  defp fragment_link(%{"link_fragment" => %{"uri" => uri}}) when is_binary(uri), do: {:link, uri}

  defp fragment_link(%{"mention_fragment" => %{"mentioned_user_info" => %{"username" => handle}}})
       when is_binary(handle),
       do: {:mention, "https://www.threads.com/@#{handle}"}

  defp fragment_link(%{"linkified_web_url" => url}) when is_binary(url), do: {:link, url}
  defp fragment_link(_fragment), do: nil

  @spec clean(term()) :: String.t() | nil
  defp clean(text) when is_binary(text) do
    text |> String.replace(@object_replacement, "") |> Lolek.Post.Text.clean(:threads)
  end

  defp clean(_text), do: nil

  @spec map(term()) :: map()
  defp map(%{} = value), do: value
  defp map(_value), do: %{}

  @spec str(term()) :: String.t() | nil
  defp str(value), do: Lolek.Post.blank_to_nil(value)
end
