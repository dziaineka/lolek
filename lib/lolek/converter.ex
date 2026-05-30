defmodule Lolek.Converter do
  @moduledoc """
  This module is responsible for converting files to the required by telegram format.
  """
  require Logger
  @compressed_name "compressed.mp4"

  @type encoding_strategy :: :compress | :convert
  @type h264_encoder :: :software | {:vaapi, String.t()}

  @spec adapt_to_telegram(Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def adapt_to_telegram({:downloaded, file_path}) do
    with :ok <- compress_video_to_telegram_size(file_path) do
      replace_original_file_with_compressed(file_path)
    end
  end

  def adapt_to_telegram(another_file_state) do
    {:ok, another_file_state}
  end

  @spec compress_video_to_telegram_size(String.t()) :: :ok | {:error, term()}
  defp compress_video_to_telegram_size(file_path) do
    if Path.extname(file_path) != ".mp4" do
      :ok
    else
      with {:ok, file_size} <- Lolek.File.file_size(file_path),
           {:ok, duration} <- video_duration(file_path) do
        case encoding_strategy(file_path, file_size, duration) do
          :passthrough -> :ok
          :too_big_media -> {:error, :too_big_media}
          strategy -> encode_video(file_path, strategy)
        end
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

  @spec encode_video(String.t(), encoding_strategy()) :: :ok | {:error, term()}
  defp encode_video(file_path, strategy) do
    new_file_path = get_compressed_file_path(file_path)

    case encode_with_h264(file_path, new_file_path, strategy) do
      :ok ->
        ensure_telegram_file_size(new_file_path)

      {:error, error} ->
        action = if strategy == :compress, do: "compressing", else: "converting"
        Logger.error("Error when #{action} video: #{inspect(error)}")
        File.rm(new_file_path)
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

  @spec h264_encoder() :: {:ok, h264_encoder()} | {:error, term()}
  defp h264_encoder do
    case Application.get_env(:lolek, :hw_acceleration, "none") do
      value when value in ["", "none"] ->
        {:ok, :software}

      "vaapi" ->
        {:ok, {:vaapi, Application.get_env(:lolek, :hw_device, "/dev/dri/renderD128")}}

      value ->
        {:error, {:unsupported_hw_acceleration, value}}
    end
  end

  @spec encoder_name(h264_encoder()) :: String.t()
  defp encoder_name(:software), do: "libx264"
  defp encoder_name({:vaapi, _device}), do: "h264_vaapi"

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

    with {:ok, duration} when duration > 0 <- video_duration(file_path) do
      video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
      audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

      # Cap video bitrate to prevent quality issues
      # Most content doesn't benefit from >10 Mbps
      video_bitrate = min(video_bitrate, 10_000)
      audio_bitrate = min(audio_bitrate, 128)

      {:ok, {"#{video_bitrate}k", "#{audio_bitrate}k"}}
    else
      {:ok, 0} -> {:error, :invalid_video_duration}
      error -> error
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

  @spec get_compressed_file_path(String.t()) :: String.t()
  defp get_compressed_file_path(file_path) do
    file_path |> Path.dirname() |> Path.join(@compressed_name)
  end

  @spec replace_original_file_with_compressed(String.t()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp replace_original_file_with_compressed(file_path) do
    new_file_path = get_compressed_file_path(file_path)

    if File.exists?(new_file_path) do
      case File.rm(file_path) do
        :ok -> {:ok, {:compressed, new_file_path}}
        {:error, reason} -> {:error, {:remove_original_failed, reason}}
      end
    else
      case File.rename(file_path, new_file_path) do
        :ok -> {:ok, {:compressed, new_file_path}}
        {:error, reason} -> {:error, {:rename_compressed_failed, reason}}
      end
    end
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
