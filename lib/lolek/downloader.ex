defmodule Lolek.Downloader do
  @moduledoc """
  This module is responsible for downloading media from the internet.
  """
  require Logger
  @downloaded_name "downloaded"
  @threads_hosts ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]

  @spec download(String.t(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, String.t()}
  def download(url, {:new_file, output_path}) do
    max_tries = Application.get_env(:lolek, :max_download_tries)
    pause = Application.get_env(:lolek, :start_download_pause)
    max_pause = Application.get_env(:lolek, :max_download_pause)
    download(url, output_path, 0, max_tries, pause, max_pause)
  end

  def download(_url, another_file_state) do
    {:ok, another_file_state}
  end

  defp download(url, output_path, tries_done, max_tries, pause, max_pause) do
    pause = min(pause, max_pause)

    case download_once(url, output_path) do
      {:ok, _} ->
        {:ok, file_path} = Lolek.File.get_file_path_by_pattern(output_path, @downloaded_name)
        {:ok, {:downloaded, file_path}}

      {:error, reason} ->
        if tries_done < max_tries do
          Logger.warning(
            "Error when downloading url: #{url}; reason: #{inspect(reason)}. Retrying..."
          )

          Process.sleep(pause)
          download(url, output_path, tries_done + 1, max_tries, pause * 2, max_pause)
        else
          raise("Error when downloading url: #{url}; reason: #{inspect(reason)}")
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
        command =
          ~c"yt-dlp --format-sort '+vcodec:h264,+acodec:aac' --recode-video mp4 -o \"#{output_file_path}\" \"#{url}\""

        :exec.run(command, [:sync, :stdout, :stderr])
    end
  end

  @spec downloader_module(String.t()) :: Lolek.ThreadsDownloader | :yt_dlp
  def downloader_module(url) do
    case URI.parse(url) do
      %URI{host: host} when host in @threads_hosts -> Lolek.ThreadsDownloader
      _ -> :yt_dlp
    end
  end
end
