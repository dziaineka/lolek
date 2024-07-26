defmodule Lolek.File do
  @moduledoc """
  This module is responsible for file operations.
  """
  require Logger

  @ready_to_telegram "ready_to_telegram"
  @compressed_name "compressed.mp4"
  @downloaded_name "downloaded"

  @type file_state ::
          {:ready_to_telegram, String.t()}
          | {:compressed, String.t()}
          | {:downloaded, String.t()}
          | {:new_file, String.t()}
          | {:sent_to_telegram_at_first, file_path :: String.t(), tg_file_id :: String.t()}

  @spec get_video_width_and_height(String.t()) :: :error | {:ok, {integer(), integer()}}
  def get_video_width_and_height(file_path) do
    command =
      ~c"ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x #{file_path}"

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, [stdout: [dimensions]]} ->
        [width, height] =
          dimensions |> String.trim() |> String.split("x") |> Enum.map(&String.to_integer/1)

        {:ok, {width, height}}

      {:error, reason} ->
        Logger.warning("Error when determining dimensions: #{inspect(reason)}")
        :error
    end
  end

  @spec get_video_duration(String.t()) :: :error | {:ok, integer()}
  def get_video_duration(file_path) do
    command =
      ~c"ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 #{file_path}"

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, [stdout: [raw_duration]]} ->
        duration = raw_duration |> String.trim() |> String.to_float() |> round()
        {:ok, duration}

      {:error, reason} ->
        Logger.warning("Error when determining duration: #{inspect(reason)}")
        :error
    end
  end

  @spec get_file_path_by_pattern(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_file_path_by_pattern(output_path, pattern) do
    case File.ls(output_path) do
      {:ok, files} -> files
      _ -> []
    end
    |> Enum.find(:not_found, fn file_name -> String.contains?(file_name, pattern) end)
    |> case do
      :not_found -> {:error, "File not found"}
      file_name -> {:ok, Path.join(output_path, file_name)}
    end
  end

  @spec move_to_ready_to_telegram(Lolek.File.file_state()) :: :ok | {:error, File.posix()}
  def move_to_ready_to_telegram({:sent_to_telegram_at_first, file_path, file_id}) do
    file_extension = Path.extname(file_path)

    folder_path =
      file_path
      |> Path.dirname()
      |> Path.join(@ready_to_telegram)

    new_file_path =
      folder_path
      |> Path.join(file_id <> file_extension)

    File.mkdir(folder_path)
    File.rename(file_path, new_file_path)
  end

  def move_to_ready_to_telegram(_another_file_state) do
    :ok
  end

  @spec get_folder_path(String.t()) :: {:ok, String.t()}
  def get_folder_path(url) do
    download_path = Application.get_env(:lolek, :download_path)
    folder_name = Lolek.Url.to_folder_name(url)
    {:ok, Path.join(download_path, folder_name)}
  end

  @spec get_file_state(String.t()) :: {:ok, Lolek.File.file_state()}
  def get_file_state(folder_path) do
    with :not_ready <- check_if_ready_to_tg(folder_path),
         :not_compressed <- check_if_compressed(folder_path),
         :not_downloaded <- check_if_downloaded(folder_path) do
      {:ok, {:new_file, folder_path}}
    else
      {:exists, state} ->
        {:ok, state}
    end
  end

  @spec check_if_ready_to_tg(String.t()) :: :not_ready | {:exists, Lolek.File.file_state()}
  defp check_if_ready_to_tg(folder_path) do
    case Path.join(folder_path, @ready_to_telegram) |> File.ls() do
      {:ok, [file_name | _]} ->
        {
          :exists,
          {:ready_to_telegram, Path.join(folder_path, file_name)}
        }

      _ ->
        :not_ready
    end
  end

  @spec check_if_compressed(String.t()) :: :not_compressed | {:exists, Lolek.File.file_state()}
  defp check_if_compressed(folder_path) do
    file_path = Path.join(folder_path, @compressed_name)

    if file_path |> File.exists?() do
      {
        :exists,
        {:compressed, file_path}
      }
    else
      :not_compressed
    end
  end

  @spec check_if_downloaded(String.t()) :: :not_downloaded | {:exists, Lolek.File.file_state()}
  defp check_if_downloaded(folder_path) do
    case get_file_path_by_pattern(folder_path, @downloaded_name) do
      {:ok, file_path} ->
        {
          :exists,
          {:downloaded, file_path}
        }

      _ ->
        :not_downloaded
    end
  end
end
