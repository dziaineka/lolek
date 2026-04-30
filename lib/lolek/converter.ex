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
    if Path.extname(file_path) != ".mp4" do
      :ok
    else
      %File.Stat{size: file_size} = File.stat!(file_path)
      {:ok, duration} = Lolek.File.get_video_duration(file_path)

      case encoding_strategy(file_path, file_size, duration) do
        :passthrough -> :ok
        :too_big_media -> {:error, :too_big_media}
        strategy -> encode_video(file_path, strategy)
      end
    end
  end

  @spec encoding_strategy(String.t(), non_neg_integer(), non_neg_integer()) ::
          :compress | :convert | :passthrough | :too_big_media
  defp encoding_strategy(file_path, file_size, duration) do
    if h264_codec?(file_path) do
      h264_encoding_strategy(file_size, duration)
    else
      non_h264_encoding_strategy(file_size, duration)
    end
  end

  @spec h264_encoding_strategy(non_neg_integer(), non_neg_integer()) ::
          :compress | :passthrough | :too_big_media
  defp h264_encoding_strategy(file_size, duration) do
    cond do
      small_enough_to_upload?(file_size) ->
        :passthrough

      compressible_file?(file_size) and compressible_duration?(duration) ->
        :compress

      true ->
        :too_big_media
    end
  end

  @spec non_h264_encoding_strategy(non_neg_integer(), non_neg_integer()) ::
          :compress | :convert | :too_big_media
  defp non_h264_encoding_strategy(file_size, duration) do
    cond do
      small_enough_to_upload?(file_size) and compressible_duration?(duration) ->
        :compress

      compressible_duration?(duration) ->
        :convert

      compressible_file?(file_size) and compressible_duration?(duration) ->
        :compress

      true ->
        :too_big_media
    end
  end

  @spec small_enough_to_upload?(non_neg_integer()) :: boolean()
  defp small_enough_to_upload?(file_size) do
    file_size <= Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)
  end

  @spec compressible_file?(non_neg_integer()) :: boolean()
  defp compressible_file?(file_size) do
    file_size <= Application.fetch_env!(:lolek, :max_file_size_to_compress)
  end

  @spec compressible_duration?(non_neg_integer()) :: boolean()
  defp compressible_duration?(duration) do
    duration <= Application.fetch_env!(:lolek, :max_duration_to_compress)
  end

  @spec encode_video(String.t(), encoding_strategy()) :: :ok | no_return()
  defp encode_video(file_path, strategy) do
    new_file_path = get_compressed_file_path(file_path)

    case encode_with_libx264(file_path, new_file_path, strategy) do
      :ok ->
        ensure_telegram_file_size(new_file_path)

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
      {:ok, result} ->
        stdout_data = Keyword.get(result, :stdout, [])
        codec = stdout_data |> List.first("") |> to_string() |> String.trim()
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
    audio_bitrate = min(audio_bitrate, 128)

    {"#{video_bitrate}k", "#{audio_bitrate}k"}
  end

  @spec ensure_telegram_file_size(String.t()) :: :ok | {:error, atom()}
  defp ensure_telegram_file_size(file_path) do
    max_file_size_to_send_to_telegram =
      Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

    %File.Stat{size: file_size} = File.stat!(file_path)

    if file_size <= max_file_size_to_send_to_telegram do
      :ok
    else
      {:error, :too_big_media}
    end
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
