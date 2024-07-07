defmodule Lolek.Downloader do
  @formats ["mp4", "webm", "m4a"]

  @spec download(String.t()) ::
          {:ok, file_path :: String.t() | {:existed, file_path :: String.t()}}
          | {:error, String.t()}
  def download(url) do
    download_path = Application.get_env(:lolek, :download_path)
    folder_name = Lolek.Url.to_folder_name(url)
    output_path = Path.join(download_path, folder_name)

    case check_if_already_downloaded(output_path) do
      {:ok, file_path} ->
        {:ok, {:existed, file_path}}

      {:error, _} ->
        download(url, @formats, output_path, nil)
    end
  end

  defp check_if_already_downloaded(output_path) do
    case File.ls(output_path) do
      {:ok, [file_path | _]} ->
        {:ok, Path.join(output_path, file_path)}

      {:ok, []} ->
        {:error, :empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download(url, [format | rest], output_path, _) do
    case Exyt.download_getting_filename(url, %{output_path: output_path, format: format}) do
      {:ok, file_path} ->
        {:ok, file_path}

      {:error, reason} ->
        download(url, rest, output_path, reason)
    end
  end

  defp download(url, [], _, reason) do
    {:error, "All formats are tried for url: #{url}. Reason: #{reason}"}
  end
end
