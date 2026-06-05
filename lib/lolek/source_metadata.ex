defmodule Lolek.SourceMetadata do
  @moduledoc """
  Fetches, sanitizes, and caches source text for media URLs.
  """

  @metadata_file_name "source_metadata.json"

  @type source_caption :: String.t() | nil

  @spec get_or_fetch(String.t(), String.t()) :: {:ok, source_caption()} | {:error, term()}
  def get_or_fetch(url, folder_path) do
    case read_cached(folder_path) do
      {:ok, caption} -> {:ok, caption}
      {:error, :enoent} -> fetch_and_cache(url, folder_path)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_cached(String.t()) :: {:ok, source_caption()} | {:error, term()}
  defp read_cached(folder_path) do
    with {:ok, contents} <- File.read(metadata_file_path(folder_path)),
         {:ok, %{"caption" => caption}} <- Jason.decode(contents),
         true <- is_nil(caption) or is_binary(caption) do
      {:ok, sanitize_caption(caption)}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Cached source metadata is invalid"}
    end
  end

  @spec fetch_and_cache(String.t(), String.t()) :: {:ok, source_caption()} | {:error, term()}
  defp fetch_and_cache(url, folder_path) do
    with {:ok, caption} <- fetch_caption(url),
         caption <- sanitize_caption(caption),
         :ok <- write_cached(folder_path, caption) do
      {:ok, caption}
    end
  end

  @spec fetch_caption(String.t()) :: {:ok, source_caption()} | {:error, term()}
  defp fetch_caption(url) do
    case Lolek.Downloader.downloader_module(url) do
      Lolek.ThreadsDownloader -> Lolek.ThreadsDownloader.caption(url)
      :yt_dlp -> fetch_yt_dlp_caption(url)
    end
  end

  @spec fetch_yt_dlp_caption(String.t()) :: {:ok, source_caption()} | {:error, term()}
  defp fetch_yt_dlp_caption(url) do
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
        |> parse_yt_dlp_caption()

      {:error, reason} ->
        {:error, {:yt_dlp_metadata, summarize_command_error(reason)}}
    end
  end

  @spec parse_yt_dlp_caption(String.t()) :: {:ok, source_caption()} | {:error, term()}
  defp parse_yt_dlp_caption(output) do
    with {:ok, metadata} when is_map(metadata) <- Jason.decode(output) do
      {:ok, metadata_caption(metadata)}
    else
      {:ok, _metadata} -> {:error, :invalid_yt_dlp_metadata}
      {:error, _reason} -> {:error, :invalid_yt_dlp_metadata}
    end
  end

  @spec summarize_command_error(term()) :: term()
  defp summarize_command_error(reason) when is_list(reason) do
    Keyword.take(reason, [:exit_status, :signal, :core_dump])
  end

  defp summarize_command_error(reason), do: reason

  @spec metadata_caption(map()) :: source_caption()
  defp metadata_caption(metadata) do
    ["description", "title", "fulltitle", "alt_title"]
    |> Enum.find_value(fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  @spec write_cached(String.t(), source_caption()) :: :ok | {:error, term()}
  defp write_cached(folder_path, caption) do
    with :ok <- File.mkdir_p(folder_path) do
      File.write(metadata_file_path(folder_path), Jason.encode!(%{caption: caption}))
    end
  end

  @spec sanitize_caption(source_caption()) :: source_caption()
  defp sanitize_caption(nil), do: nil

  defp sanitize_caption(caption) do
    caption
    |> remove_urls()
    |> normalize_newlines()
    |> String.split("\n", trim: false)
    |> Enum.map(&sanitize_caption_line/1)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> case do
      "" -> nil
      sanitized -> sanitized
    end
  end

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

  @spec metadata_file_path(String.t()) :: String.t()
  defp metadata_file_path(folder_path), do: Path.join(folder_path, @metadata_file_name)

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
