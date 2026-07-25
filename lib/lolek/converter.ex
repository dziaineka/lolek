defmodule Lolek.Converter do
  @moduledoc """
  This module is responsible for converting files to the required by telegram format.
  """
  require Logger
  @compressed_name "compressed.mp4"

  @type encoding_strategy :: :compress | :convert
  @type h264_encoder :: :software | {:vaapi, String.t()} | {:qsv, String.t()}

  @spec adapt_to_telegram(Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def adapt_to_telegram({:downloaded_media, cache_root, files}) do
    case prepare_media_files(cache_root, files) do
      [] -> {:error, :no_usable_media_files}
      prepared_files -> {:ok, {:prepared_media, cache_root, prepared_files}}
    end
  end

  def adapt_to_telegram(another_file_state) do
    {:ok, another_file_state}
  end

  @spec prepare_media_files(String.t(), [String.t()]) :: [String.t()]
  defp prepare_media_files(cache_root, files) do
    files
    |> Enum.reduce([], fn file_path, prepared_files ->
      case prepare_media_file(cache_root, file_path) do
        {:ok, prepared_path} ->
          [prepared_path | prepared_files]

        {:error, reason} ->
          relative_path = Path.relative_to(file_path, cache_root)
          Logger.warning("Omitting media #{relative_path}: #{inspect(reason)}")
          prepared_files
      end
    end)
    |> Enum.reverse()
  end

  @spec prepare_media_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp prepare_media_file(cache_root, file_path) do
    if Lolek.GalleryDownloader.video_file?(file_path) do
      prepare_video(file_path, prepared_video_path(cache_root, file_path))
    else
      with :ok <- ensure_telegram_file_size(file_path) do
        {:ok, file_path}
      end
    end
  end

  @spec prepared_video_path(String.t(), String.t()) :: String.t()
  defp prepared_video_path(cache_root, file_path) do
    if Path.dirname(file_path) == cache_root do
      Path.join(cache_root, @compressed_name)
    else
      file_path <> ".telegram.mp4"
    end
  end

  @spec prepare_video(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp prepare_video(file_path, prepared_path) do
    with {:ok, strategy} <- video_preparation_strategy(file_path) do
      case strategy do
        :passthrough ->
          {:ok, file_path}

        strategy ->
          prepare_encoded_video(file_path, prepared_path, strategy)
      end
    end
  end

  @spec prepare_encoded_video(String.t(), String.t(), encoding_strategy()) ::
          {:ok, String.t()} | {:error, term()}
  defp prepare_encoded_video(file_path, prepared_path, strategy) do
    with :ok <- encode_video(file_path, prepared_path, strategy),
         :ok <- remove_encoded_source(file_path, prepared_path) do
      {:ok, prepared_path}
    end
  end

  @spec video_preparation_strategy(String.t()) ::
          {:ok, encoding_strategy() | :passthrough} | {:error, term()}
  defp video_preparation_strategy(file_path) do
    with {:ok, file_size} <- Lolek.File.file_size(file_path),
         {:ok, duration} <- video_duration(file_path) do
      case encoding_strategy(file_path, file_size, duration) do
        :passthrough -> {:ok, :passthrough}
        :too_big_media -> {:error, :too_big_media}
        strategy -> {:ok, strategy}
      end
    end
  end

  @spec encoding_strategy(String.t(), non_neg_integer(), non_neg_integer()) ::
          :compress | :convert | :passthrough | :too_big_media
  defp encoding_strategy(file_path, file_size, duration) do
    cond do
      small_enough_to_upload?(file_size) and telegram_video?(file_path) ->
        :passthrough

      not compressible_file?(file_size) or not compressible_duration?(duration) ->
        :too_big_media

      small_enough_to_upload?(file_size) ->
        :convert

      true ->
        :compress
    end
  end

  @spec telegram_video?(String.t()) :: boolean()
  defp telegram_video?(file_path) do
    Path.extname(file_path) |> String.downcase() == ".mp4" and h264_codec?(file_path)
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

  @spec encode_video(String.t(), String.t(), encoding_strategy()) :: :ok | {:error, term()}
  defp encode_video(file_path, prepared_path, strategy) do
    case encode_with_h264(file_path, prepared_path, strategy) do
      :ok ->
        case ensure_telegram_file_size(prepared_path) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(prepared_path)
            error
        end

      {:error, error} ->
        action = if strategy == :compress, do: "compressing", else: "converting"
        Logger.error("Error when #{action} video: #{inspect(error)}")
        File.rm(prepared_path)
        {:error, error}
    end
  end

  @spec encode_with_h264(String.t(), String.t(), encoding_strategy()) ::
          :ok | {:error, term()}
  defp encode_with_h264(file_path, new_file_path, strategy) do
    with {:ok, encoder} <- h264_encoder() do
      case encode_with_encoder(file_path, new_file_path, strategy, encoder) do
        {:error, reason} when is_tuple(encoder) ->
          Logger.warning(
            "Hardware encoder #{encoder_name(encoder)} failed: #{inspect(reason)}. Retrying with libx264"
          )

          File.rm(new_file_path)
          encode_with_encoder(file_path, new_file_path, strategy, :software)

        result ->
          result
      end
    end
  end

  @spec encode_with_encoder(String.t(), String.t(), encoding_strategy(), h264_encoder()) ::
          :ok | {:error, term()}
  defp encode_with_encoder(file_path, new_file_path, strategy, encoder) do
    with {:ok, args} <- build_encode_args(file_path, new_file_path, strategy, encoder) do
      action = if strategy == :compress, do: "Compressed", else: "Converted to H.264"

      case Lolek.Command.run("ffmpeg", args,
             timeout: command_timeout(:convert_command_timeout_seconds)
           ) do
        {:ok, result} ->
          Logger.info("#{action} video with #{encoder_name(encoder)}: #{inspect(result)}")
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @spec build_encode_args(String.t(), String.t(), encoding_strategy(), h264_encoder()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp build_encode_args(file_path, new_file_path, :compress, :software) do
    with {:ok, {video_bitrate, audio_bitrate}} <- calculate_target_bitrates(file_path) do
      # One-pass encoding with target bitrate
      {:ok,
       [
         "-y",
         "-threads",
         "4",
         "-i",
         file_path,
         "-c:v",
         "libx264",
         "-preset",
         "fast",
         "-tune",
         "fastdecode",
         "-threads",
         "4",
         "-profile:v",
         "baseline",
         "-level",
         "3.0",
         "-pix_fmt",
         "yuv420p",
         "-b:v",
         video_bitrate,
         "-c:a",
         "aac",
         "-b:a",
         audio_bitrate,
         "-movflags",
         "+faststart",
         new_file_path
       ]}
    end
  end

  defp build_encode_args(file_path, new_file_path, :compress, {:vaapi, device}) do
    with {:ok, {video_bitrate, audio_bitrate}} <- calculate_target_bitrates(file_path) do
      {:ok,
       [
         "-y",
         "-hwaccel",
         "vaapi",
         "-hwaccel_device",
         device,
         "-hwaccel_output_format",
         "vaapi",
         "-vaapi_device",
         device,
         "-i",
         file_path,
         "-vf",
         "format=nv12,hwupload",
         "-c:v",
         "h264_vaapi",
         "-profile:v",
         "constrained_baseline",
         "-level",
         "3.0",
         "-b:v",
         video_bitrate,
         "-c:a",
         "aac",
         "-b:a",
         audio_bitrate,
         "-movflags",
         "+faststart",
         new_file_path
       ]}
    end
  end

  defp build_encode_args(file_path, new_file_path, :compress, {:qsv, device}) do
    with {:ok, {video_bitrate, audio_bitrate}} <- calculate_target_bitrates(file_path) do
      {:ok,
       [
         "-y",
         "-init_hw_device",
         "qsv=hw,child_device=#{device},child_device_type=vaapi",
         "-filter_hw_device",
         "hw",
         "-hwaccel",
         "qsv",
         "-hwaccel_device",
         "hw",
         "-hwaccel_output_format",
         "qsv",
         "-i",
         file_path,
         "-c:v",
         "h264_qsv",
         "-profile:v",
         "main",
         "-b:v",
         video_bitrate,
         "-c:a",
         "aac",
         "-b:a",
         audio_bitrate,
         "-movflags",
         "+faststart",
         new_file_path
       ]}
    end
  end

  defp build_encode_args(file_path, new_file_path, :convert, :software) do
    {:ok,
     [
       "-y",
       "-threads",
       "4",
       "-i",
       file_path,
       "-c:v",
       "libx264",
       "-preset",
       "fast",
       "-tune",
       "fastdecode",
       "-threads",
       "4",
       "-profile:v",
       "baseline",
       "-level",
       "3.0",
       "-pix_fmt",
       "yuv420p",
       "-crf",
       "23",
       "-c:a",
       "aac",
       "-b:a",
       "128k",
       "-movflags",
       "+faststart",
       new_file_path
     ]}
  end

  defp build_encode_args(file_path, new_file_path, :convert, {:vaapi, device}) do
    {:ok,
     [
       "-y",
       "-hwaccel",
       "vaapi",
       "-hwaccel_device",
       device,
       "-hwaccel_output_format",
       "vaapi",
       "-vaapi_device",
       device,
       "-i",
       file_path,
       "-vf",
       "format=nv12,hwupload",
       "-c:v",
       "h264_vaapi",
       "-profile:v",
       "constrained_baseline",
       "-level",
       "3.0",
       "-qp",
       "23",
       "-c:a",
       "aac",
       "-b:a",
       "128k",
       "-movflags",
       "+faststart",
       new_file_path
     ]}
  end

  defp build_encode_args(file_path, new_file_path, :convert, {:qsv, device}) do
    {:ok,
     [
       "-y",
       "-init_hw_device",
       "qsv=hw,child_device=#{device},child_device_type=vaapi",
       "-filter_hw_device",
       "hw",
       "-hwaccel",
       "qsv",
       "-hwaccel_device",
       "hw",
       "-hwaccel_output_format",
       "qsv",
       "-i",
       file_path,
       "-c:v",
       "h264_qsv",
       "-global_quality",
       "23",
       "-profile:v",
       "main",
       "-c:a",
       "aac",
       "-b:a",
       "128k",
       "-movflags",
       "+faststart",
       new_file_path
     ]}
  end

  @spec h264_encoder() :: {:ok, h264_encoder()} | {:error, term()}
  defp h264_encoder do
    case Application.fetch_env!(:lolek, :hw_acceleration) do
      "none" ->
        {:ok, :software}

      "vaapi" ->
        {:ok, {:vaapi, Application.fetch_env!(:lolek, :hw_device)}}

      "qsv" ->
        {:ok, {:qsv, Application.fetch_env!(:lolek, :hw_device)}}

      value ->
        {:error, {:unsupported_hw_acceleration, value}}
    end
  end

  @spec encoder_name(h264_encoder()) :: String.t()
  defp encoder_name(:software), do: "libx264"
  defp encoder_name({:vaapi, _device}), do: "h264_vaapi"
  defp encoder_name({:qsv, _device}), do: "h264_qsv"

  @spec h264_codec?(String.t()) :: boolean()
  defp h264_codec?(file_path) do
    case Lolek.Command.run(
           "ffprobe",
           [
             "-v",
             "error",
             "-select_streams",
             "v:0",
             "-show_entries",
             "stream=codec_name",
             "-of",
             "default=noprint_wrappers=1:nokey=1",
             file_path
           ],
           timeout: command_timeout(:probe_command_timeout_seconds)
         ) do
      {:ok, result} ->
        stdout_data = Keyword.get(result, :stdout, [])
        codec = stdout_data |> IO.iodata_to_binary() |> String.trim()
        codec == "h264"

      _ ->
        false
    end
  end

  @spec calculate_target_bitrates(String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  defp calculate_target_bitrates(file_path) do
    max_video_size = Application.fetch_env!(:lolek, :max_video_size_to_send_to_telegram)
    max_audio_size = Application.fetch_env!(:lolek, :max_audio_size_to_send_to_telegram)

    case video_duration(file_path) do
      {:ok, duration} when duration > 0 ->
        video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
        audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

        # Cap video bitrate to prevent quality issues
        # Most content doesn't benefit from >10 Mbps
        video_bitrate = min(video_bitrate, 10_000)
        audio_bitrate = min(audio_bitrate, 128)

        {:ok, {"#{video_bitrate}k", "#{audio_bitrate}k"}}

      {:ok, 0} ->
        {:error, :invalid_video_duration}

      error ->
        error
    end
  end

  @spec ensure_telegram_file_size(String.t()) :: :ok | {:error, term()}
  defp ensure_telegram_file_size(file_path) do
    max_file_size_to_send_to_telegram =
      Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

    with {:ok, file_size} <- Lolek.File.file_size(file_path) do
      if file_size <= max_file_size_to_send_to_telegram do
        :ok
      else
        {:error, :too_big_media}
      end
    end
  end

  @spec video_duration(String.t()) :: {:ok, non_neg_integer()} | {:error, :video_duration}
  defp video_duration(file_path) do
    case Lolek.File.get_video_duration(file_path) do
      {:ok, duration} -> {:ok, duration}
      :error -> {:error, :video_duration}
    end
  end

  @spec remove_encoded_source(String.t(), String.t()) :: :ok | {:error, term()}
  defp remove_encoded_source(file_path, prepared_path) do
    case File.rm(file_path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(prepared_path)
        {:error, {:remove_original_failed, reason}}
    end
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
