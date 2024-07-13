defmodule Lolek.Converter do
  require Logger
  @compressed_name "compressed.mp4"

  def adapt_to_telegram({:downloaded, file_path}) do
    extname = Path.extname(file_path)

    case extname do
      ".mp4" ->
        case compress_video_to_telegram_size(file_path) do
          :ok ->
            delete_original_file(file_path)

          error ->
            error
        end

      _ ->
        delete_original_file(file_path)
    end
  end

  def adapt_to_telegram(another_file_state) do
    {:ok, another_file_state}
  end

  defp compress_video_to_telegram_size(file_path) do
    file_size = File.stat!(file_path).size

    max_file_size =
      Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

    if file_size <= max_file_size do
      :ok
    else
      compress_video(file_path)
    end
  end

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

  defp calculate_target_bitrates(file_path) do
    max_video_size = Application.fetch_env!(:lolek, :max_video_size_to_send_to_telegram)
    max_audio_size = Application.fetch_env!(:lolek, :max_audio_size_to_send_to_telegram)
    duration = get_duration(file_path)

    video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
    audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

    {"#{video_bitrate}k", "#{audio_bitrate}k"}
  end

  defp get_compressed_file_path(file_path) do
    file_path |> Path.dirname() |> Path.join(@compressed_name)
  end

  defp delete_original_file(file_path) do
    new_file_path = get_compressed_file_path(file_path)

    if File.exists?(new_file_path) do
      File.rm!(file_path)
      {:ok, {:compressed, new_file_path}}
    else
      File.rename(file_path, new_file_path)
      {:ok, {:compressed, new_file_path}}
    end
  end

  defp get_duration(file_path) do
    command =
      ~c"ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"#{file_path}\""

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, [stdout: [raw_duration]]} ->
        raw_duration |> String.trim() |> String.to_float()

      {:error, error} ->
        Logger.error("Error when getting duration: #{inspect(error)}")
        raise("Error when getting duration: #{inspect(error)}")
    end
  end
end
