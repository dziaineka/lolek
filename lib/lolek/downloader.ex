defmodule Lolek.Downloader do
  @moduledoc """
  This module is responsible for downloading media from the internet.
  """
  require Logger
  @downloaded_name "downloaded.mp4"
  @threads_hosts ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]

  @type formats_probe :: :not_probed | :has_formats | :no_formats | :inconclusive
  @type download_error :: :no_video_formats | String.t()

  @spec download(String.t(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, download_error()}
  def download(url, {:new_file, output_path}) do
    max_tries = Application.fetch_env!(:lolek, :max_download_tries)
    pause = Application.fetch_env!(:lolek, :start_download_pause)
    max_pause = Application.fetch_env!(:lolek, :max_download_pause)
    download(url, output_path, 1, max_tries, pause, max_pause, :not_probed)
  end

  def download(_url, another_file_state) do
    {:ok, another_file_state}
  end

  @spec download(
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          formats_probe()
        ) :: {:ok, Lolek.File.file_state()} | {:error, download_error()}
  defp download(url, output_path, tries_done, max_tries, pause, max_pause, formats_probe) do
    pause = min(pause, max_pause)
    log_url = Lolek.Url.normalize_for_log(url)

    case download_once(url, output_path) do
      {:ok, _} ->
        case Lolek.File.get_file_path_by_pattern(output_path, @downloaded_name) do
          {:ok, file_path} -> {:ok, {:downloaded, file_path}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        formats_probe = maybe_probe_formats(url, formats_probe)
        error_reason = download_error_reason(reason, formats_probe)

        if retryable_download_error?(formats_probe) and tries_done < max_tries do
          Logger.warning(
            "Error when downloading url: #{log_url}; reason: #{inspect(error_reason)}. Retrying..."
          )

          Process.sleep(pause)

          download(
            url,
            output_path,
            tries_done + 1,
            max_tries,
            pause * 2,
            max_pause,
            formats_probe
          )
        else
          {:error, download_error(log_url, error_reason)}
        end
    end
  end

  @spec download_once(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defp download_once(url, output_path) do
    output_file_path = Path.join(output_path, @downloaded_name)

    case downloader_module(url) do
      Lolek.ThreadsDownloader ->
        Lolek.ThreadsDownloader.download(url, output_file_path)

      :yt_dlp ->
        Lolek.Command.run(
          "yt-dlp",
          [
            "--format-sort",
            "+vcodec:h264,+acodec:aac",
            "--remux-video",
            "mp4",
            "--max-filesize",
            max_download_file_size(),
            "--no-playlist",
            "-o",
            output_file_path,
            url
          ],
          timeout: command_timeout(:download_command_timeout_seconds)
        )
    end
  end

  @spec max_download_file_size() :: String.t()
  defp max_download_file_size do
    :lolek
    |> Application.fetch_env!(:max_file_size_to_compress)
    |> to_string()
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end

  @spec downloader_module(String.t()) :: Lolek.ThreadsDownloader | :yt_dlp
  def downloader_module(url) do
    case URI.parse(url) do
      %URI{host: host} when host in @threads_hosts -> Lolek.ThreadsDownloader
      _ -> :yt_dlp
    end
  end

  @spec maybe_probe_formats(String.t(), formats_probe()) :: formats_probe()
  defp maybe_probe_formats(url, :not_probed) do
    case downloader_module(url) do
      :yt_dlp -> probe_formats(url)
      Lolek.ThreadsDownloader -> :inconclusive
    end
  end

  defp maybe_probe_formats(_url, formats_probe), do: formats_probe

  @spec probe_formats(String.t()) :: formats_probe()
  defp probe_formats(url) do
    case Lolek.Command.run(
           "yt-dlp",
           [
             "--simulate",
             "--ignore-no-formats-error",
             "--print",
             "%(formats)#j",
             "--no-playlist",
             url
           ],
           timeout: command_timeout(:download_command_timeout_seconds)
         ) do
      {:ok, output} -> parse_formats_probe(output)
      {:error, _reason} -> :inconclusive
    end
  end

  @spec parse_formats_probe(keyword()) :: formats_probe()
  defp parse_formats_probe(output) do
    output
    |> Keyword.get(:stdout, [])
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, []} -> :no_formats
      {:ok, formats} when is_list(formats) -> :has_formats
      _ -> :inconclusive
    end
  end

  @spec retryable_download_error?(formats_probe()) :: boolean()
  defp retryable_download_error?(:no_formats), do: false
  defp retryable_download_error?(_formats_probe), do: true

  @spec download_error_reason(term(), formats_probe()) :: term()
  defp download_error_reason(_reason, :no_formats), do: :no_video_formats
  defp download_error_reason(reason, _formats_probe), do: reason

  @spec download_error(String.t(), term()) :: download_error()
  defp download_error(_log_url, :no_video_formats), do: :no_video_formats

  defp download_error(log_url, reason),
    do: "Error when downloading url: #{log_url}; reason: #{inspect(reason)}"
end
