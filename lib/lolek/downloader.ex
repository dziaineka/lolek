defmodule Lolek.Downloader do
  @moduledoc """
  This module is responsible for downloading media from the internet.
  """
  require Logger
  @downloaded_name "downloaded.mp4"
  @threads_hosts ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]

  @spec download(String.t(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, String.t()}
  def download(url, {:new_file, output_path}) do
    max_tries = max(Application.get_env(:lolek, :max_download_tries), 1)
    pause = Application.get_env(:lolek, :start_download_pause)
    max_pause = Application.get_env(:lolek, :max_download_pause)
    download(url, output_path, 1, max_tries, pause, max_pause)
  end

  def download(_url, another_file_state) do
    {:ok, another_file_state}
  end

  defp download(url, output_path, tries_done, max_tries, pause, max_pause) do
    pause = min(pause, max_pause)

    case download_once(url, output_path) do
      {:ok, _} ->
        case Lolek.File.get_file_path_by_pattern(output_path, @downloaded_name) do
          {:ok, file_path} -> {:ok, {:downloaded, file_path}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        if tries_done < max_tries do
          Logger.warning(
            "Error when downloading url: #{url}; reason: #{inspect(reason)}. Retrying..."
          )

          Process.sleep(pause)
          download(url, output_path, tries_done + 1, max_tries, pause * 2, max_pause)
        else
          {:error, "Error when downloading url: #{url}; reason: #{inspect(reason)}"}
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
            "--recode-video",
            "mp4",
            "--max-filesize",
            max_download_file_size(),
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
end
