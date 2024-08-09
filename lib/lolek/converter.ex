defmodule Lolek.Converter do
  @moduledoc """
  This module is responsible for converting files to the required by telegram format.
  """
  require Logger
  @compressed_name "compressed.mp4"

  @spec adapt_to_telegram(Lolek.File.file_state()) :: {:ok, Lolek.File.file_state()} | {:error, atom()}
  def adapt_to_telegram({:downloaded, file_path}) do
    with :ok <- compress_video_to_telegram_size(file_path) do
      replace_original_file_with_compressed(file_path)
    end
  end

  def adapt_to_telegram(another_file_state) do
    {:ok, another_file_state}
  end

  @spec compress_video_to_telegram_size(String.t()) :: :ok | no_return()
  defp compress_video_to_telegram_size(file_path) do
    extname = Path.extname(file_path)

    case extname do
      ".mp4" ->
        file_size = File.stat!(file_path).size
        {:ok, duration} = Lolek.File.get_video_duration(file_path)

        max_file_size_to_send_to_telegram =
          Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

        max_file_size_to_compress =
          Application.fetch_env!(:lolek, :max_file_size_to_compress)

        max_duration_to_compress =
          Application.fetch_env!(:lolek, :max_duration_to_compress)

        cond do
          file_size <= max_file_size_to_send_to_telegram ->
            :ok

          file_size <= max_file_size_to_compress and duration <= max_duration_to_compress ->
            compress_video(file_path)

          true ->
            {:error, :too_big_media}
        end

      _ ->
        :ok
    end
  end

  @spec compress_video(String.t()) :: :ok | no_return()
  defp compress_video(file_path) do
    new_file_path = get_compressed_file_path(file_path)
    {video_bitrate, audio_bitrate} = calculate_target_bitrates(file_path)

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
    log_name = "#{timestamp}_ffmpeg2pass.log"
    log_path = Path.join("/tmp", log_name)

    command =
      ~c"ffmpeg -y -i \"#{file_path}\" -c:v libx264 -b:v \"#{video_bitrate}\" -pass 1 -passlogfile #{log_path} -an -f mp4 /dev/null && ffmpeg -i \"#{file_path}\" -c:v libx264 -b:v \"#{video_bitrate}\" -pass 2 -passlogfile #{log_path} -c:a aac -b:a \"#{audio_bitrate}\" \"#{new_file_path}\""

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, result} ->
        Logger.info("Compressed video: #{inspect(result)}")
        File.rm(log_path)
        :ok

      {:error, error} ->
        Logger.error("Error when compressing video: #{inspect(error)}")
        raise("Error when compressing video: #{inspect(error)}")
    end
  end

  @spec calculate_target_bitrates(String.t()) :: {String.t(), String.t()}
  defp calculate_target_bitrates(file_path) do
    max_video_size = Application.fetch_env!(:lolek, :max_video_size_to_send_to_telegram)
    max_audio_size = Application.fetch_env!(:lolek, :max_audio_size_to_send_to_telegram)
    {:ok, duration} = Lolek.File.get_video_duration(file_path)

    video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
    audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

    {"#{video_bitrate}k", "#{audio_bitrate}k"}
  end

  @spec get_compressed_file_path(String.t()) :: String.t()
  defp get_compressed_file_path(file_path) do
    file_path |> Path.dirname() |> Path.join(@compressed_name)
  end

  @spec replace_original_file_with_compressed(String.t()) :: {:ok, Lolek.File.file_state()}
  defp replace_original_file_with_compressed(file_path) do
    new_file_path = get_compressed_file_path(file_path)

    if File.exists?(new_file_path) do
      File.rm!(file_path)
      {:ok, {:compressed, new_file_path}}
    else
      File.rename(file_path, new_file_path)
      {:ok, {:compressed, new_file_path}}
    end
  end
end
