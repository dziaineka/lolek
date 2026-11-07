defmodule Lolek.SourceMetadata do
  @moduledoc """
  Fetches, merges, and caches the source post metadata (`Lolek.Post`) of URLs.
  """

  @post_file_name "post.json"
  @max_title_length 160
  @threads_handle ~r{\A/@([^/]+)/}

  require Logger

  @doc """
  Returns the cached post of the URL, or fetches the post and caches it.
  """
  @spec get_or_fetch(String.t(), String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  def get_or_fetch(url, folder_path) do
    case read_cached(folder_path) do
      {:ok, post} -> {:ok, enrich_cached(post, folder_path)}
      {:error, :enoent} -> fetch_and_cache(url, folder_path)
      {:error, reason} -> {:error, reason}
    end
  end

  # Posts cached before the linked posts were fetched get them now.
  @spec enrich_cached(Lolek.Post.t(), String.t()) :: Lolek.Post.t()
  defp enrich_cached(post, folder_path) do
    if Lolek.Post.Enricher.needs_enrichment?(post) do
      post = Lolek.Post.Enricher.enrich(post)
      _ = write_cached(folder_path, post)
      post
    else
      post
    end
  end

  @spec read_cached(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp read_cached(folder_path) do
    with {:ok, map} <- read_json(Path.join(folder_path, @post_file_name)),
         {:error, :invalid_post} <- Lolek.Post.from_map(map) do
      {:error, "Cached source metadata is invalid"}
    end
  end

  @spec read_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_json(path) do
    with {:ok, contents} <- File.read(path) do
      case Jason.decode(contents) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> {:error, "Cached source metadata is invalid"}
      end
    end
  end

  @spec fetch_and_cache(String.t(), String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp fetch_and_cache(url, folder_path) do
    with {:ok, post} <- fetch_post(url) do
      # Linked posts are fetched after the download, when the gallery-dl data is known.
      post = finalize(post, url)
      _ = write_cached(folder_path, post)
      {:ok, post}
    end
  end

  @doc """
  Merges the gallery-dl metadata (`info.json` files) of a downloaded gallery into the
  post, fetches the linked posts, and caches the result.
  """
  @spec merge_gallery_metadata(Lolek.Post.t(), String.t(), String.t()) :: Lolek.Post.t()
  def merge_gallery_metadata(%Lolek.Post{} = post, folder_path, gallery_dir) do
    case read_gallery_post(gallery_dir) do
      %Lolek.Post{} = gallery_post ->
        merged =
          gallery_post
          |> Lolek.Post.merge(post)
          |> finalize(post.url)
          |> Lolek.Post.Enricher.enrich()

        _ = write_cached(folder_path, merged)
        merged

      nil ->
        enrich_cached(post, folder_path)
    end
  end

  @spec read_gallery_post(String.t()) :: Lolek.Post.t() | nil
  defp read_gallery_post(gallery_dir) do
    gallery_dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.find_value(fn path ->
      case read_json(path) do
        {:ok, map} -> Lolek.Post.GalleryDl.parse(map)
        _ -> nil
      end
    end)
  end

  @spec fetch_post(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp fetch_post(url) do
    case Lolek.Downloader.downloader_module(url) do
      Lolek.ThreadsDownloader -> fetch_threads_post(url)
      Lolek.YoutubePostDownloader -> Lolek.YoutubePostDownloader.post(url)
      :yt_dlp -> fetch_generic_post(url)
    end
  end

  @spec fetch_generic_post(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp fetch_generic_post(url) do
    if Lolek.Post.platform_from_url(url) == :bluesky do
      case Lolek.Post.Bluesky.fetch(url) do
        {:ok, post} ->
          {:ok, post}

        {:error, reason} ->
          Logger.info("Bluesky API failed, trying yt-dlp; reason: #{inspect(reason)}")
          fetch_yt_dlp_post(url)
      end
    else
      fetch_yt_dlp_post(url)
    end
  end

  @spec fetch_threads_post(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp fetch_threads_post(url) do
    with {:ok, caption} <- Lolek.ThreadsDownloader.caption(url) do
      handle =
        case Regex.run(@threads_handle, URI.parse(url).path || "") do
          [_, handle] -> handle
          _ -> nil
        end

      {:ok,
       %Lolek.Post{
         platform: :threads,
         source: :page,
         url: url,
         author: Lolek.Post.author(nil, handle, handle && "https://www.threads.com/@#{handle}"),
         text: Lolek.Post.Text.clean(caption, :threads)
       }}
    end
  end

  @spec fetch_yt_dlp_post(String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp fetch_yt_dlp_post(url) do
    case Lolek.Command.run(
           "yt-dlp",
           yt_dlp_cookies_args() ++
             ["--dump-single-json", "--skip-download", "--no-playlist", url],
           timeout: command_timeout(:download_command_timeout_seconds)
         ) do
      {:ok, result} ->
        result
        |> Keyword.get(:stdout, [])
        |> IO.iodata_to_binary()
        |> parse_yt_dlp_metadata(url)

      {:error, reason} ->
        {:error, {:yt_dlp_metadata, summarize_command_error(reason)}}
    end
  end

  @spec parse_yt_dlp_metadata(String.t(), String.t()) :: {:ok, Lolek.Post.t()} | {:error, term()}
  defp parse_yt_dlp_metadata(output, url) do
    case Jason.decode(output) do
      {:ok, %{} = metadata} -> {:ok, Lolek.Post.YtDlp.parse(metadata, url)}
      _ -> {:error, :invalid_yt_dlp_metadata}
    end
  end

  # The title is the name of uploaded files.
  @spec finalize(Lolek.Post.t(), String.t() | nil) :: Lolek.Post.t()
  defp finalize(%Lolek.Post{} = post, url) do
    %{
      post
      | url: post.url || url,
        title: sanitize_title(post.title) || sanitize_title(post.text)
    }
  end

  @spec summarize_command_error(term()) :: term()
  defp summarize_command_error(reason) do
    if Keyword.keyword?(reason) do
      Keyword.take(reason, [:exit_status, :signal, :core_dump])
    else
      reason
    end
  end

  @spec write_cached(String.t(), Lolek.Post.t()) :: :ok | {:error, term()}
  defp write_cached(folder_path, post) do
    with :ok <- File.mkdir_p(folder_path) do
      folder_path
      |> Path.join(@post_file_name)
      |> File.write(Jason.encode!(Lolek.Post.to_map(post)))
    end
  end

  @spec sanitize_title(String.t() | nil) :: String.t() | nil
  defp sanitize_title(nil), do: nil

  defp sanitize_title(title) do
    title
    |> HtmlEntities.decode()
    |> String.replace(~r{https?://\S+}iu, "")
    |> String.replace(~r/[\x00-\x1F\x7F\/\\:*?"<>|]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_title_length)
    |> String.trim()
    |> case do
      "" -> nil
      "." -> nil
      ".." -> nil
      sanitized -> sanitized
    end
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end

  @spec yt_dlp_cookies_args() :: [String.t()]
  defp yt_dlp_cookies_args do
    case Application.fetch_env!(:lolek, :yt_dlp_cookies_file) do
      path when is_binary(path) ->
        writable = Path.join(System.tmp_dir!(), "yt_dlp_cookies.txt")
        unless File.exists?(writable), do: File.copy!(path, writable)
        ["--cookies", writable]

      nil ->
        []
    end
  end
end
