defmodule Lolek.SourceMetadata do
  @moduledoc """
  Fetches, sanitizes, and caches source text for media URLs.
  """

  @metadata_file_name "source_metadata.json"
  @max_title_length 160
  @empty_metadata %{caption: nil, title: nil}

  @type source_caption :: String.t() | nil
  @type source_title :: String.t() | nil
  @type t :: %{caption: source_caption(), title: source_title()}

  @spec empty() :: t()
  def empty, do: @empty_metadata

  @spec get_or_fetch(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get_or_fetch(url, folder_path) do
    case read_cached(folder_path) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, :enoent} -> fetch_and_cache(url, folder_path)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_cached(String.t()) :: {:ok, t()} | {:error, term()}
  defp read_cached(folder_path) do
    with {:ok, contents} <- File.read(metadata_file_path(folder_path)),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(contents),
         {:ok, metadata} <- cached_metadata(metadata) do
      {:ok, metadata}
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, _metadata} ->
        {:error, "Cached source metadata is invalid"}
    end
  end

  @spec cached_metadata(map()) :: {:ok, t()} | {:error, String.t()}
  defp cached_metadata(metadata) do
    caption = Map.get(metadata, "caption")
    title = Map.get(metadata, "title")

    if valid_optional_string?(caption) and valid_optional_string?(title) do
      caption = sanitize_caption(caption)
      title = sanitize_title(title) || title_from_caption(caption)
      {:ok, %{caption: caption, title: title}}
    else
      {:error, "Cached source metadata is invalid"}
    end
  end

  @spec fetch_and_cache(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  defp fetch_and_cache(url, folder_path) do
    with {:ok, metadata} <- fetch_metadata(url),
         metadata <- sanitize_metadata(metadata),
         :ok <- write_cached(folder_path, metadata) do
      {:ok, metadata}
    end
  end

  @spec fetch_metadata(String.t()) :: {:ok, t()} | {:error, term()}
  defp fetch_metadata(url) do
    case Lolek.Downloader.downloader_module(url) do
      Lolek.ThreadsDownloader -> fetch_threads_metadata(url)
      :yt_dlp -> fetch_yt_dlp_metadata(url)
    end
  end

  @spec cache_gallery_caption(String.t(), String.t()) :: :ok
  def cache_gallery_caption(folder_path, raw_caption) do
    metadata = sanitize_metadata(%{caption: raw_caption, title: nil})

    _ =
      with :ok <- File.mkdir_p(folder_path) do
        File.write(metadata_file_path(folder_path), Jason.encode!(metadata))
      end

    :ok
  end

  @spec fetch_threads_metadata(String.t()) :: {:ok, t()} | {:error, term()}
  defp fetch_threads_metadata(url) do
    with {:ok, caption} <- Lolek.ThreadsDownloader.caption(url) do
      {:ok, %{caption: caption, title: caption}}
    end
  end

  @spec fetch_yt_dlp_metadata(String.t()) :: {:ok, t()} | {:error, term()}
  defp fetch_yt_dlp_metadata(url) do
    case Lolek.Command.run(
           "yt-dlp",
           [
             "--dump-single-json",
             "--skip-download",
             "--no-playlist",
             url
           ],
           timeout: command_timeout(:download_command_timeout_seconds)
         ) do
      {:ok, result} ->
        result
        |> Keyword.get(:stdout, [])
        |> IO.iodata_to_binary()
        |> parse_yt_dlp_metadata()

      {:error, reason} ->
        {:error, {:yt_dlp_metadata, summarize_command_error(reason)}}
    end
  end

  @spec parse_yt_dlp_metadata(String.t()) :: {:ok, t()} | {:error, term()}
  defp parse_yt_dlp_metadata(output) do
    case Jason.decode(output) do
      {:ok, metadata} when is_map(metadata) ->
        caption = metadata_caption(metadata)

        {:ok,
         %{
           caption: caption,
           title: metadata_title(metadata) || caption
         }}

      {:ok, _metadata} ->
        {:error, :invalid_yt_dlp_metadata}

      {:error, _reason} ->
        {:error, :invalid_yt_dlp_metadata}
    end
  end

  @spec summarize_command_error(term()) :: term()
  defp summarize_command_error(reason) do
    if Keyword.keyword?(reason) do
      Keyword.take(reason, [:exit_status, :signal, :core_dump])
    else
      reason
    end
  end

  @spec metadata_title(map()) :: source_title()
  defp metadata_title(metadata) do
    ["title", "fulltitle", "alt_title"]
    |> Enum.find_value(&metadata_string(metadata, &1))
  end

  @spec metadata_caption(map()) :: source_caption()
  defp metadata_caption(metadata) do
    ["description", "title", "fulltitle", "alt_title"]
    |> Enum.find_value(&metadata_string(metadata, &1))
  end

  @spec metadata_string(map(), String.t()) :: String.t() | nil
  defp metadata_string(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @spec write_cached(String.t(), t()) :: :ok | {:error, term()}
  defp write_cached(folder_path, metadata) do
    with :ok <- File.mkdir_p(folder_path) do
      File.write(metadata_file_path(folder_path), Jason.encode!(metadata))
    end
  end

  @spec sanitize_metadata(t()) :: t()
  defp sanitize_metadata(metadata) do
    caption = sanitize_caption(metadata.caption)
    title = sanitize_title(metadata.title) || title_from_caption(caption)

    %{caption: caption, title: title}
  end

  @spec sanitize_caption(source_caption()) :: source_caption()
  defp sanitize_caption(nil), do: nil

  defp sanitize_caption(caption) do
    caption
    |> decode_html_entities()
    |> remove_urls()
    |> normalize_newlines()
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &sanitize_caption_line/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> case do
      "" -> nil
      sanitized -> sanitized
    end
  end

  @spec sanitize_title(source_title()) :: source_title()
  defp sanitize_title(nil), do: nil

  defp sanitize_title(title) do
    title
    |> decode_html_entities()
    |> remove_urls()
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

  @spec title_from_caption(source_caption()) :: source_title()
  defp title_from_caption(nil), do: nil
  defp title_from_caption(caption), do: sanitize_title(caption)

  @spec decode_html_entities(String.t()) :: String.t()
  defp decode_html_entities(text), do: HtmlEntities.decode(text)

  @spec remove_urls(String.t()) :: String.t()
  defp remove_urls(text), do: String.replace(text, ~r{https?://\S+}iu, "")

  @spec normalize_newlines(String.t()) :: String.t()
  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  @spec sanitize_caption_line(String.t()) :: String.t()
  defp sanitize_caption_line(line) do
    line
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @spec valid_optional_string?(term()) :: boolean()
  defp valid_optional_string?(value), do: is_nil(value) or is_binary(value)

  @spec metadata_file_path(String.t()) :: String.t()
  defp metadata_file_path(folder_path), do: Path.join(folder_path, @metadata_file_name)

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
