defmodule Lolek.Converter do
  @moduledoc """
  This module is responsible for converting files to the required by telegram format.
  Uses libx264 software encoder for all video encoding operations.
  """
  require Logger
  @compressed_name "compressed.mp4"

  @type encoding_strategy :: :compress | :convert

  @spec adapt_to_telegram(Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, atom()}
  def adapt_to_telegram({:downloaded, file_path}) do
    with :ok <- compress_video_to_telegram_size(file_path) do
      replace_original_file_with_compressed(file_path)
    end
  end

  def adapt_to_telegram(another_file_state) do
    {:ok, another_file_state}
  end

  @spec compress_video_to_telegram_size(String.t()) :: :ok | {:error, atom()}
  defp compress_video_to_telegram_size(file_path) do
    extname = Path.extname(file_path)

    case extname do
      ".mp4" ->
        %File.Stat{size: file_size} = File.stat!(file_path)
        {:ok, duration} = Lolek.File.get_video_duration(file_path)

        max_file_size_to_send_to_telegram =
          Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

        max_file_size_to_compress =
          Application.fetch_env!(:lolek, :max_file_size_to_compress)

        max_duration_to_compress =
          Application.fetch_env!(:lolek, :max_duration_to_compress)

        needs_codec_conversion = not h264_codec?(file_path)

        cond do
          needs_codec_conversion and duration <= max_duration_to_compress ->
            encode_video(file_path, :convert)

          file_size <= max_file_size_to_send_to_telegram ->
            :ok

          file_size <= max_file_size_to_compress and duration <= max_duration_to_compress ->
            encode_video(file_path, :compress)

          true ->
            {:error, :too_big_media}
        end

      _ ->
        :ok
    end
  end

  @spec encode_video(String.t(), encoding_strategy()) :: :ok | no_return()
  defp encode_video(file_path, strategy) do
    new_file_path = get_compressed_file_path(file_path)

    case encode_with_libx264(file_path, new_file_path, strategy) do
      :ok ->
        :ok

      {:error, error} ->
        action = if strategy == :compress, do: "compressing", else: "converting"
        Logger.error("Error when #{action} video: #{inspect(error)}")
        raise("Error when #{action} video: #{inspect(error)}")
    end
  end

  @spec encode_with_libx264(String.t(), String.t(), encoding_strategy()) ::
          :ok | {:error, term()}
  defp encode_with_libx264(file_path, new_file_path, strategy) do
    command = build_encode_command(file_path, new_file_path, strategy)

    action = if strategy == :compress, do: "Compressed", else: "Converted to H.264"

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, result} ->
        Logger.info("#{action} video with libx264: #{inspect(result)}")
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  @spec build_encode_command(String.t(), String.t(), encoding_strategy()) :: charlist()
  defp build_encode_command(file_path, new_file_path, :compress) do
    {video_bitrate, audio_bitrate} = calculate_target_bitrates(file_path)

    # One-pass encoding with target bitrate
    # Using -threads 4 for RPi 4B optimization
    ~c"ffmpeg -y -threads 4 -i \"#{file_path}\" -c:v libx264 -preset fast -tune fastdecode -threads 4 -profile:v baseline -level 3.0 -pix_fmt yuv420p -b:v \"#{video_bitrate}\" -c:a aac -b:a \"#{audio_bitrate}\" -movflags +faststart \"#{new_file_path}\""
  end

  defp build_encode_command(file_path, new_file_path, :convert) do
    # Software encoder: use CRF for quality-based encoding
    # Using -threads 4 for RPi 4B optimization
    ~c"ffmpeg -y -threads 4 -i \"#{file_path}\" -c:v libx264 -preset fast -tune fastdecode -threads 4 -profile:v baseline -level 3.0 -pix_fmt yuv420p -crf 23 -c:a aac -b:a 128k -movflags +faststart \"#{new_file_path}\""
  end

  @spec h264_codec?(String.t()) :: boolean()
  defp h264_codec?(file_path) do
    command =
      ~c"ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \"#{file_path}\""

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, [{:stdout, codec_output}, {:stderr, _}]} ->
        codec = codec_output |> to_string() |> String.trim()
        codec == "h264"

      _ ->
        false
    end
  end

  @spec calculate_target_bitrates(String.t()) :: {String.t(), String.t()}
  defp calculate_target_bitrates(file_path) do
    max_video_size = Application.fetch_env!(:lolek, :max_video_size_to_send_to_telegram)
    max_audio_size = Application.fetch_env!(:lolek, :max_audio_size_to_send_to_telegram)
    {:ok, duration} = Lolek.File.get_video_duration(file_path)

    video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
    audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

    # Cap video bitrate to prevent quality issues
    # Most content doesn't benefit from >10 Mbps
    video_bitrate = min(video_bitrate, 10_000)

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
