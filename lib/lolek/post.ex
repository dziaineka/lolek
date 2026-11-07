defmodule Lolek.Post do
  @moduledoc """
  Describes a source post (author, text, links, stats, and linked posts) that is used
  to build a Telegram rich message that looks like the original post.
  """

  @platforms ~w(twitter bluesky threads instagram tiktok facebook youtube coub generic)a
  @platform_hosts [
    {["x.com", "twitter.com"], :twitter},
    {["bsky.app"], :bluesky},
    {["threads.com", "threads.net"], :threads},
    {["instagram.com"], :instagram},
    {["tiktok.com"], :tiktok},
    {["facebook.com", "fb.watch"], :facebook},
    {["youtube.com", "youtu.be"], :youtube},
    {["coub.com"], :coub}
  ]
  @sources ~w(api gallery_dl page yt_dlp cache)a
  @facet_types ~w(link mention tag)a
  @media_types ~w(photo video)a
  @stat_keys ~w(likes reposts replies quotes views bookmarks)a
  @extra_keys ~w(music location reply_id linked_posts)a
  # A higher number wins when two posts are merged.
  @source_priority %{api: 4, gallery_dl: 3, page: 2, yt_dlp: 1, cache: 0}

  @type platform ::
          :twitter
          | :bluesky
          | :threads
          | :instagram
          | :tiktok
          | :facebook
          | :youtube
          | :coub
          | :generic
  @type source :: :api | :gallery_dl | :page | :yt_dlp | :cache
  @type author :: %{
          name: String.t() | nil,
          handle: String.t() | nil,
          url: String.t() | nil,
          verified: boolean()
        }
  @typedoc "A link inside `text`. `start` and `stop` are byte offsets."
  @type facet :: %{
          start: non_neg_integer(),
          stop: non_neg_integer(),
          type: :link | :mention | :tag,
          value: String.t()
        }
  @type stat_key :: :likes | :reposts | :replies | :quotes | :views | :bookmarks
  @type stats :: %{optional(stat_key()) => non_neg_integer()}
  @type remote_media :: %{type: :photo | :video, url: String.t()}
  @type link_card :: %{url: String.t(), title: String.t() | nil, description: String.t() | nil}
  @type extra_key :: :music | :location | :reply_id | :linked_posts
  @type t :: %__MODULE__{
          platform: platform(),
          source: source(),
          url: String.t() | nil,
          title: String.t() | nil,
          author: author() | nil,
          text: String.t() | nil,
          facets: [facet()] | nil,
          published_at: DateTime.t() | nil,
          stats: stats(),
          quoted: t() | nil,
          reply_to: t() | nil,
          media: [remote_media()],
          link_card: link_card() | nil,
          extra: %{optional(extra_key()) => String.t()}
        }

  defstruct platform: :generic,
            source: :cache,
            url: nil,
            title: nil,
            author: nil,
            text: nil,
            facets: nil,
            published_at: nil,
            stats: %{},
            quoted: nil,
            reply_to: nil,
            media: [],
            link_card: nil,
            extra: %{}

  @doc "Returns a post without data for the given URL."
  @spec empty(String.t() | nil) :: t()
  def empty(url \\ nil), do: %__MODULE__{platform: platform_from_url(url), url: url}

  @doc "Returns the platform of a post URL."
  @spec platform_from_url(String.t() | nil) :: platform()
  def platform_from_url(nil), do: :generic

  def platform_from_url(url) do
    host = url |> URI.parse() |> Map.get(:host) |> Kernel.||("") |> String.downcase()

    Enum.find_value(@platform_hosts, :generic, fn {domains, platform} ->
      if host_match?(host, domains), do: platform
    end)
  end

  @spec host_match?(String.t(), [String.t()]) :: boolean()
  defp host_match?(host, domains) do
    Enum.any?(domains, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  @doc """
  Merges two posts. For each field, the value of the post with the higher source
  priority is used when it is present.
  """
  @spec merge(t() | nil, t() | nil) :: t() | nil
  def merge(nil, other), do: other
  def merge(post, nil), do: post

  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    {primary, fallback} = if priority(a) >= priority(b), do: {a, b}, else: {b, a}

    {text, facets} =
      if present?(primary.text),
        do: {primary.text, primary.facets},
        else: {fallback.text, fallback.facets}

    %__MODULE__{
      platform: if(primary.platform == :generic, do: fallback.platform, else: primary.platform),
      source: primary.source,
      url: primary.url || fallback.url,
      title: primary.title || fallback.title,
      author: merge_author(primary.author, fallback.author),
      text: text,
      facets: facets,
      published_at: primary.published_at || fallback.published_at,
      stats: Map.merge(fallback.stats, primary.stats),
      quoted: merge(primary.quoted, fallback.quoted),
      reply_to: merge(primary.reply_to, fallback.reply_to),
      media: if(primary.media == [], do: fallback.media, else: primary.media),
      link_card: primary.link_card || fallback.link_card,
      extra: Map.merge(fallback.extra, primary.extra)
    }
  end

  @spec priority(t()) :: non_neg_integer()
  defp priority(%__MODULE__{source: source}), do: Map.fetch!(@source_priority, source)

  @spec merge_author(author() | nil, author() | nil) :: author() | nil
  defp merge_author(nil, other), do: other
  defp merge_author(author, nil), do: author

  defp merge_author(primary, fallback) do
    %{
      name: primary.name || fallback.name,
      handle: primary.handle || fallback.handle,
      url: primary.url || fallback.url,
      verified: primary.verified or fallback.verified
    }
  end

  @doc "Builds an author map. Returns nil when the name and the handle are both empty."
  @spec author(String.t() | nil, String.t() | nil, String.t() | nil, boolean()) :: author() | nil
  def author(name, handle, url, verified \\ false) do
    name = blank_to_nil(name)
    handle = handle |> blank_to_nil() |> strip_at()

    if is_nil(name) and is_nil(handle) do
      nil
    else
      %{name: name, handle: handle, url: blank_to_nil(url), verified: verified == true}
    end
  end

  @spec strip_at(String.t() | nil) :: String.t() | nil
  defp strip_at(nil), do: nil
  defp strip_at("@" <> handle), do: blank_to_nil(handle)
  defp strip_at(handle), do: handle

  @doc "Builds a stats map, without negative, empty, or non-integer values."
  @spec stats(keyword()) :: stats()
  def stats(values) do
    values
    |> Enum.flat_map(fn {key, value} ->
      case to_count(value) do
        count when is_integer(count) and key in @stat_keys -> [{key, count}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @spec to_count(term()) :: non_neg_integer() | nil
  defp to_count(value) when is_integer(value) and value >= 0, do: value

  defp to_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> count
      _ -> nil
    end
  end

  defp to_count(_value), do: nil

  @doc "Builds an extra map, without empty values."
  @spec extra(keyword()) :: %{optional(extra_key()) => String.t()}
  def extra(values) do
    values
    |> Enum.flat_map(fn
      {key, value} when key in @extra_keys and is_integer(value) and value > 0 ->
        [{key, Integer.to_string(value)}]

      {key, value} when key in @extra_keys and is_binary(value) ->
        if present?(value), do: [{key, value}], else: []

      _ ->
        []
    end)
    |> Map.new()
  end

  @doc "Converts a Unix timestamp or a date string to a UTC date-time."
  @spec parse_datetime(term()) :: DateTime.t() | nil
  def parse_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  def parse_datetime(value) when is_float(value), do: value |> trunc() |> parse_datetime()

  def parse_datetime(value) when is_binary(value) do
    with {:error, _} <- iso_datetime(value),
         {:error, _} <- naive_datetime(value),
         {:error, _} <- compact_date(value) do
      case Integer.parse(value) do
        {seconds, ""} -> parse_datetime(seconds)
        _ -> nil
      end
    else
      {:ok, datetime} -> datetime
    end
  end

  def parse_datetime(_value), do: nil

  @spec iso_datetime(String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp iso_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      error -> error
    end
  end

  @spec naive_datetime(String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp naive_datetime(value) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      {:ok, naive |> NaiveDateTime.truncate(:second) |> DateTime.from_naive!("Etc/UTC")}
    end
  end

  # yt-dlp "upload_date" is YYYYMMDD.
  @spec compact_date(String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp compact_date(<<y::binary-4, m::binary-2, d::binary-2>>) do
    with {:ok, date} <- Date.from_iso8601("#{y}-#{m}-#{d}") do
      DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp compact_date(_value), do: {:error, :invalid_format}

  @doc "Returns nil for nil, non-strings, and blank strings."
  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def blank_to_nil(_value), do: nil

  @spec present?(term()) :: boolean()
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Returns true when the post has no data that a message can show."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = post) do
    is_nil(post.author) and not present?(post.text) and is_nil(post.quoted) and
      is_nil(post.reply_to) and post.stats == %{}
  end

  @doc "Converts a post to a JSON-compatible map for the cache."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = post) do
    %{
      "platform" => Atom.to_string(post.platform),
      "source" => Atom.to_string(post.source),
      "url" => post.url,
      "title" => post.title,
      "author" => post.author && Map.new(post.author, fn {k, v} -> {Atom.to_string(k), v} end),
      "text" => post.text,
      "facets" =>
        post.facets &&
          Enum.map(post.facets, fn facet ->
            %{
              "start" => facet.start,
              "stop" => facet.stop,
              "type" => Atom.to_string(facet.type),
              "value" => facet.value
            }
          end),
      "published_at" => post.published_at && DateTime.to_iso8601(post.published_at),
      "stats" => Map.new(post.stats, fn {k, v} -> {Atom.to_string(k), v} end),
      "quoted" => post.quoted && to_map(post.quoted),
      "reply_to" => post.reply_to && to_map(post.reply_to),
      "media" => Enum.map(post.media, &%{"type" => Atom.to_string(&1.type), "url" => &1.url}),
      "link_card" =>
        post.link_card && Map.new(post.link_card, fn {k, v} -> {Atom.to_string(k), v} end),
      "extra" => Map.new(post.extra, fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

  @doc "Reads a post from a map that `to_map/1` made."
  @spec from_map(term()) :: {:ok, t()} | {:error, :invalid_post}
  def from_map(%{} = map) do
    {:ok, from_map!(map)}
  rescue
    _ -> {:error, :invalid_post}
  end

  def from_map(_map), do: {:error, :invalid_post}

  @spec from_map!(map()) :: t()
  defp from_map!(map) do
    %__MODULE__{
      platform: to_known_atom(map["platform"], @platforms, :generic),
      source: to_known_atom(map["source"], @sources, :cache),
      url: optional_string!(map["url"]),
      title: optional_string!(map["title"]),
      author: author_from_map(map["author"]),
      text: optional_string!(map["text"]),
      facets: facets_from_map(map["facets"]),
      published_at: parse_datetime(map["published_at"]),
      stats: stats_from_map(map["stats"]),
      quoted: nested_from_map(map["quoted"]),
      reply_to: nested_from_map(map["reply_to"]),
      media: media_from_map(map["media"]),
      link_card: link_card_from_map(map["link_card"]),
      extra: extra_from_map(map["extra"])
    }
  end

  @spec to_known_atom(term(), [atom()], atom()) :: atom()
  defp to_known_atom(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp to_known_atom(_value, _allowed, default), do: default

  @spec optional_string!(term()) :: String.t() | nil
  defp optional_string!(nil), do: nil
  defp optional_string!(value) when is_binary(value), do: value

  @spec author_from_map(term()) :: author() | nil
  defp author_from_map(nil), do: nil

  defp author_from_map(%{} = map) do
    author(
      optional_string!(map["name"]),
      optional_string!(map["handle"]),
      optional_string!(map["url"]),
      map["verified"] == true
    )
  end

  @spec facets_from_map(term()) :: [facet()] | nil
  defp facets_from_map(nil), do: nil

  defp facets_from_map(list) when is_list(list) do
    Enum.map(list, fn %{"start" => start, "stop" => stop, "value" => value} = facet
                      when is_integer(start) and is_integer(stop) and is_binary(value) ->
      type = to_known_atom(facet["type"], @facet_types, nil)
      if is_nil(type), do: raise(ArgumentError, "invalid facet type")
      %{start: start, stop: stop, type: type, value: value}
    end)
  end

  @spec stats_from_map(term()) :: stats()
  defp stats_from_map(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_known_atom(key, @stat_keys, nil), value} end)
    |> Enum.reject(fn {key, _value} -> is_nil(key) end)
    |> stats()
  end

  defp stats_from_map(_value), do: %{}

  @spec nested_from_map(term()) :: t() | nil
  defp nested_from_map(nil), do: nil
  defp nested_from_map(%{} = map), do: from_map!(map)

  @spec media_from_map(term()) :: [remote_media()]
  defp media_from_map(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"type" => type, "url" => url} when is_binary(url) ->
        case to_known_atom(type, @media_types, nil) do
          nil -> []
          type -> [%{type: type, url: url}]
        end

      _ ->
        []
    end)
  end

  defp media_from_map(_value), do: []

  @spec link_card_from_map(term()) :: link_card() | nil
  defp link_card_from_map(%{"url" => url} = map) when is_binary(url) do
    %{
      url: url,
      title: optional_string!(map["title"]),
      description: optional_string!(map["description"])
    }
  end

  defp link_card_from_map(_value), do: nil

  @spec extra_from_map(term()) :: %{optional(extra_key()) => String.t()}
  defp extra_from_map(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_known_atom(key, @extra_keys, nil), value} end)
    |> Enum.reject(fn {key, _value} -> is_nil(key) end)
    |> extra()
  end

  defp extra_from_map(_value), do: %{}
end
