defmodule Lolek.Downloader do
  @moduledoc """
  This module is responsible for downloading media from the internet.
  """
  @downloaded_name "downloaded"

  @spec download(String.t(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, String.t()}
  def download(url, {:new_file, output_path}) do
    download(url, output_path, nil)
  end

  def download(_url, another_file_state) do
    {:ok, another_file_state}
  end

  defp download(url, output_path, _) do
    output_file_path = Path.join(output_path, @downloaded_name)
    command = ~c"yt-dlp -o \"#{output_file_path}\" \"#{url}\""

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, _} ->
        {:ok, file_path} = Lolek.File.get_file_path_by_pattern(output_path, @downloaded_name)
        {:ok, {:downloaded, file_path}}

      {:error, reason} ->
        raise("Error when downloading: #{inspect(reason)}")
    end
  end
end
