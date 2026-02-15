defmodule Lolek.Converter do
  @moduledoc """
  This module is responsible for converting files to the required by telegram format.
  Supports both hardware (h264_v4l2m2m) and software (libx264) encoding with automatic fallback.
  """
  require Logger
  @compressed_name "compressed.mp4"

  @type encoder_config :: %{
          codec: String.t(),
          extra_args: String.t(),
          scale: nil | {integer(), integer()}
        }

  @type encoding_strategy :: :compress | :convert

  # Hardware encoder configuration for Raspberry Pi 4B V4L2 M2M
  @hw_encoder_config %{
    codec: "h264_v4l2m2m",
    extra_args: "-num_output_buffers 32 -num_capture_buffers 16",
    scale: nil
  }

  # Input flags for hardware encoder to fix timestamp issues
  # -fflags +genpts: regenerate presentation timestamps before decoding
  @hw_input_flags "-fflags +genpts"

  # Output flags for hardware encoder
  # -fps_mode cfr: constant frame rate mode for stable output (fixes non-monotonic DTS)
  # -r 30: limit framerate to 30fps (RPi 4B hardware encoder struggles with 60fps at 1080p)
  @hw_output_flags "-fps_mode cfr -r 30"

  # Software encoder configuration with RPi-optimized settings
  @sw_encoder_config %{
    codec: "libx264",
    extra_args: "-preset fast -tune fastdecode -threads 4",
    scale: nil
  }

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

    case try_encode_with_fallback(file_path, new_file_path, strategy) do
      :ok ->
        :ok

      {:error, error} ->
        action = if strategy == :compress, do: "compressing", else: "converting"
        Logger.error("Error when #{action} video: #{inspect(error)}")
        raise("Error when #{action} video: #{inspect(error)}")
    end
  end

  @spec try_encode_with_fallback(String.t(), String.t(), encoding_strategy()) ::
          :ok | {:error, term()}
  defp try_encode_with_fallback(file_path, new_file_path, strategy) do
    encoder_config = get_encoder_config(file_path)
    command = build_encode_command(file_path, new_file_path, strategy, encoder_config)

    action = if strategy == :compress, do: "Compressed", else: "Converted to H.264"

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, result} ->
        Logger.info("#{action} video with #{encoder_config.codec}: #{inspect(result)}")
        :ok

      {:error, error} when encoder_config.codec != "libx264" ->
        Logger.warning(
          "Hardware encoder #{encoder_config.codec} failed: #{inspect(error)}, falling back to software encoder"
        )

        # Clean up any partial output from failed hardware encoding
        if File.exists?(new_file_path), do: File.rm(new_file_path)

        fallback_command =
          build_encode_command(file_path, new_file_path, strategy, @sw_encoder_config)

        case :exec.run(fallback_command, [:sync, :stdout, :stderr]) do
          {:ok, result} ->
            Logger.info("#{action} video with fallback libx264: #{inspect(result)}")
            :ok

          {:error, fallback_error} ->
            {:error, fallback_error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @spec build_encode_command(
          String.t(),
          String.t(),
          encoding_strategy(),
          encoder_config()
        ) :: charlist()
  defp build_encode_command(file_path, new_file_path, :compress, %{
         codec: "libx264",
         extra_args: extra_args,
         scale: _
       }) do
    {video_bitrate, audio_bitrate} = calculate_target_bitrates(file_path)
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
    log_name = "#{timestamp}_ffmpeg2pass.log"
    log_path = Path.join("/tmp", log_name)

    # Two-pass encoding for better quality with software encoder
    # Using -threads 4 for RPi 4B optimization
    ~c"ffmpeg -y -threads 4 -i \"#{file_path}\" -c:v libx264 #{extra_args} -profile:v baseline -level 3.0 -pix_fmt yuv420p -b:v \"#{video_bitrate}\" -pass 1 -passlogfile #{log_path} -an -f mp4 /dev/null && ffmpeg -threads 4 -i \"#{file_path}\" -c:v libx264 #{extra_args} -profile:v baseline -level 3.0 -pix_fmt yuv420p -b:v \"#{video_bitrate}\" -pass 2 -passlogfile #{log_path} -c:a aac -b:a \"#{audio_bitrate}\" -movflags +faststart \"#{new_file_path}\""
  end

  defp build_encode_command(file_path, new_file_path, :compress, %{
         codec: codec,
         extra_args: extra_args,
         scale: scale
       }) do
    {video_bitrate, audio_bitrate} = calculate_target_bitrates(file_path)
    scale_filter = build_scale_filter(scale)

    # Hardware encoder: single-pass encoding (two-pass not supported by V4L2 M2M)
    # Input flags before -i, output flags after -i to fix timestamp issues
    ~c"ffmpeg -y -threads 4 #{@hw_input_flags} -i \"#{file_path}\" #{@hw_output_flags} #{scale_filter} -c:v #{codec} #{extra_args} -b:v \"#{video_bitrate}\" -c:a aac -b:a \"#{audio_bitrate}\" -movflags +faststart \"#{new_file_path}\""
  end

  defp build_encode_command(file_path, new_file_path, :convert, %{
         codec: "libx264",
         extra_args: extra_args,
         scale: _
       }) do
    # Software encoder: use CRF for quality-based encoding
    # Using -threads 4 for RPi 4B optimization
    ~c"ffmpeg -y -threads 4 -i \"#{file_path}\" -c:v libx264 #{extra_args} -profile:v baseline -level 3.0 -pix_fmt yuv420p -crf 23 -c:a aac -b:a 128k -movflags +faststart \"#{new_file_path}\""
  end

  defp build_encode_command(file_path, new_file_path, :convert, %{
         codec: codec,
         extra_args: extra_args,
         scale: scale
       }) do
    video_bitrate = calculate_conversion_bitrate(file_path, scale)
    scale_filter = build_scale_filter(scale)

    # Hardware encoder: use bitrate-based encoding (CRF not supported)
    # Input flags before -i, output flags after -i to fix timestamp issues
    ~c"ffmpeg -y -threads 4 #{@hw_input_flags} -i \"#{file_path}\" #{@hw_output_flags} #{scale_filter} -c:v #{codec} #{extra_args} -b:v \"#{video_bitrate}\" -c:a aac -b:a 128k -movflags +faststart \"#{new_file_path}\""
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

  @spec get_encoder_config(String.t()) :: encoder_config()
  defp get_encoder_config(file_path) do
    use_hw_encoder? = Application.fetch_env!(:lolek, :use_hw_encoder?)

    case use_hw_encoder? do
      true ->
        cond do
          not hw_encoder_available?() ->
            Logger.warning(
              "Hardware encoder requested but h264_v4l2m2m not available, using software encoder"
            )
            @sw_encoder_config

          true ->
            case get_scale_for_hw_encoder(file_path) do
              {:ok, nil} ->
                Logger.info("Using hardware encoder: h264_v4l2m2m")
                @hw_encoder_config

              {:ok, {width, height}} ->
                Logger.info(
                  "Video resolution too high for hardware encoder, downscaling to #{width}x#{height}"
                )
                %{@hw_encoder_config | scale: {width, height}}

              :error ->
                Logger.info("Could not determine resolution, using hardware encoder without scaling")
                @hw_encoder_config
            end
        end

      _ ->
        Logger.info("Using software encoder: libx264")
        @sw_encoder_config
    end
  end

  # Raspberry Pi hardware encoder (h264_v4l2m2m) typically supports up to 1920x1080
  # Returns {:ok, nil} if no scaling needed, {:ok, {width, height}} if downscaling needed, or :error
  @spec get_scale_for_hw_encoder(String.t()) :: {:ok, nil | {integer(), integer()}} | :error
  defp get_scale_for_hw_encoder(file_path) do
    case Lolek.File.get_video_width_and_height(file_path) do
      {:ok, {width, height}} ->
        max_pixels = 1920 * 1080
        video_pixels = width * height

        if video_pixels <= max_pixels do
          {:ok, nil}
        else
          # Calculate scaled dimensions maintaining aspect ratio
          # Fit to 1920x1080 while preserving aspect ratio
          aspect_ratio = width / height
          {scaled_width, scaled_height} =
            if aspect_ratio > 16 / 9 do
              # Width is the limiting factor
              {1920, round(1920 / aspect_ratio)}
            else
              # Height is the limiting factor
              {round(1080 * aspect_ratio), 1080}
            end

          # Ensure dimensions are even (required by most video codecs)
          scaled_width = scaled_width - rem(scaled_width, 2)
          scaled_height = scaled_height - rem(scaled_height, 2)

          {:ok, {scaled_width, scaled_height}}
        end

      :error ->
        :error
    end
  end

  @spec build_scale_filter(nil | {integer(), integer()}) :: String.t()
  defp build_scale_filter(nil), do: ""
  defp build_scale_filter({width, height}), do: "-vf scale=#{width}:#{height}"

  @spec hw_encoder_available?() :: boolean()
  defp hw_encoder_available? do
    # Check if h264_v4l2m2m encoder is available in ffmpeg
    command = ~c"ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_v4l2m2m"

    case :exec.run(command, [:sync, :stdout, :stderr]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec calculate_target_bitrates(String.t()) :: {String.t(), String.t()}
  defp calculate_target_bitrates(file_path) do
    max_video_size = Application.fetch_env!(:lolek, :max_video_size_to_send_to_telegram)
    max_audio_size = Application.fetch_env!(:lolek, :max_audio_size_to_send_to_telegram)
    {:ok, duration} = Lolek.File.get_video_duration(file_path)

    video_bitrate = (max_video_size * 8 / duration / 1000) |> round()
    audio_bitrate = (max_audio_size * 8 / duration / 1000) |> round()

    # Cap video bitrate to prevent hardware encoder issues
    # Most content doesn't benefit from >10 Mbps
    video_bitrate = min(video_bitrate, 10_000)

    {"#{video_bitrate}k", "#{audio_bitrate}k"}
  end

  # Calculate appropriate bitrate for codec conversion based on resolution
  # Uses conservative bitrates suitable for hardware encoding
  @spec calculate_conversion_bitrate(String.t(), nil | {integer(), integer()}) :: String.t()
  defp calculate_conversion_bitrate(file_path, scale) do
    # Determine target resolution (after scaling if applicable)
    {width, height} =
      case scale do
        nil ->
          case Lolek.File.get_video_width_and_height(file_path) do
            {:ok, dimensions} -> dimensions
            :error -> {1280, 720}
          end

        {w, h} ->
          {w, h}
      end

    # Calculate total pixels
    pixels = width * height

    # Determine bitrate based on resolution
    # These are conservative bitrates suitable for hardware encoding
    bitrate_kbps =
      cond do
        # 4K (3840x2160 = 8,294,400 pixels)
        pixels >= 8_000_000 -> 8000
        # 1440p (2560x1440 = 3,686,400 pixels)
        pixels >= 3_500_000 -> 5000
        # 1080p (1920x1080 = 2,073,600 pixels)
        pixels >= 2_000_000 -> 3500
        # 720p (1280x720 = 921,600 pixels)
        pixels >= 900_000 -> 2500
        # 480p (854x480 = 409,920 pixels)
        pixels >= 400_000 -> 1500
        # < 480p
        true -> 1000
      end

    "#{bitrate_kbps}k"
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
