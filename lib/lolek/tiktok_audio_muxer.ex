defmodule Lolek.TiktokAudioMuxer do
  @moduledoc """
  Muxes TikTok adaptive audio back into gallery-dl video-only downloads.
  """
  require Logger

  @audio_bitrate "128k"
  @muxed_name "downloaded-with-audio.mp4"

  @type media_streams :: %{video?: boolean(), audio?: boolean()}

  @spec maybe_mux(String.t(), String.t()) :: :ok | {:error, term()}
  def maybe_mux(gallery_dir, file_path) do
    case audio_urls(gallery_dir) do
      {:ok, audio_urls} ->
        maybe_mux_with_audio_urls(file_path, audio_urls)

      :no_audio_urls ->
        :ok
    end
  end

  @spec maybe_mux_with_audio_urls(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp maybe_mux_with_audio_urls(file_path, audio_urls) do
    case media_streams(file_path) do
      {:ok, %{video?: true, audio?: false}} -> mux_first_available(file_path, audio_urls)
      {:ok, _streams} -> :ok
      {:error, reason} -> skip_after_probe_failure(reason)
    end
  end

  @spec skip_after_probe_failure(term()) :: :ok
  defp skip_after_probe_failure(reason) do
    Logger.warning("Skipping TikTok audio mux because ffprobe failed: #{inspect(reason)}")
    :ok
  end

  @spec media_streams(String.t()) :: {:ok, media_streams()} | {:error, term()}
  defp media_streams(file_path) do
    case Lolek.Command.run(
           "ffprobe",
           [
             "-v",
             "error",
             "-show_entries",
             "stream=codec_type",
             "-of",
             "csv=p=0",
             file_path
           ],
           timeout: command_timeout(:probe_command_timeout_seconds)
         ) do
      {:ok, result} ->
        streams =
          result
          |> Keyword.get(:stdout, [])
          |> IO.iodata_to_binary()
          |> String.split(~r/\R/u, trim: true)

        {:ok, %{video?: "video" in streams, audio?: "audio" in streams}}

      {:error, reason} ->
        {:error, {:ffprobe_streams, reason}}
    end
  end

  @spec audio_urls(String.t()) :: {:ok, [String.t()]} | :no_audio_urls | {:error, term()}
  defp audio_urls(gallery_dir) do
    gallery_dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.find_value(:no_audio_urls, &audio_urls_from_json/1)
    |> case do
      {:ok, [_ | _] = urls} -> {:ok, urls}
      :no_audio_urls -> :no_audio_urls
      {:error, _reason} = error -> error
    end
  end

  @spec audio_urls_from_json(String.t()) :: {:ok, [String.t()]} | nil
  defp audio_urls_from_json(json_path) do
    with {:ok, content} <- File.read(json_path),
         {:ok, data} when is_map(data) <- Jason.decode(content),
         [_ | _] = urls <- tiktok_audio_urls(data) do
      {:ok, urls}
    else
      _ -> nil
    end
  end

  @spec tiktok_audio_urls(map()) :: [String.t()]
  defp tiktok_audio_urls(data) do
    data
    |> get_in(["video", "bitrateAudioInfo"])
    |> case do
      entries when is_list(entries) ->
        entries
        |> Enum.sort_by(&bitrate/1, :desc)
        |> Enum.flat_map(&entry_audio_urls/1)

      _ ->
        []
    end
    |> Kernel.++(music_urls(data))
    |> Enum.uniq()
  end

  @spec bitrate(term()) :: integer()
  defp bitrate(%{"Bitrate" => bitrate}) when is_integer(bitrate), do: bitrate
  defp bitrate(_entry), do: 0

  @spec entry_audio_urls(term()) :: [String.t()]
  defp entry_audio_urls(%{"UrlList" => urls}) when is_map(urls) do
    # TikTok signs several equivalent audio URLs. In practice the direct CDN
    # MainUrl/BackupUrl can reject ffmpeg with 403, while the aweme fallback URL
    # still works, so try every advertised variant instead of trusting one field.
    ["FallbackUrl", "MainUrl", "BackupUrl"]
    |> Enum.map(&Map.get(urls, &1))
    |> Enum.flat_map(&validated_url/1)
  end

  defp entry_audio_urls(_entry), do: []

  @spec music_urls(map()) :: [String.t()]
  defp music_urls(data) do
    case get_in(data, ["music", "playUrl"]) do
      url when is_binary(url) -> validated_url(url)
      _ -> []
    end
  end

  @spec validated_url(term()) :: [String.t()]
  defp validated_url(url) when is_binary(url) do
    url = String.trim(url)

    if valid_url?(url), do: [url], else: []
  end

  defp validated_url(_url), do: []

  @spec valid_url?(String.t()) :: boolean()
  defp valid_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} ->
        scheme in ["http", "https"] and is_binary(host) and host != ""

      {:error, _reason} ->
        false
    end
  end

  @spec mux_first_available(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp mux_first_available(file_path, audio_urls) do
    do_mux_first_available(file_path, audio_urls, [])
  end

  @spec do_mux_first_available(String.t(), [String.t()], [term()]) :: :ok | {:error, term()}
  defp do_mux_first_available(_file_path, [], reasons) do
    {:error, {:tiktok_audio_mux_failed, Enum.reverse(reasons)}}
  end

  defp do_mux_first_available(file_path, [audio_url | rest], reasons) do
    case mux_audio(file_path, audio_url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("TikTok audio mux attempt failed: #{inspect(reason)}")
        do_mux_first_available(file_path, rest, [reason | reasons])
    end
  end

  @spec mux_audio(String.t(), String.t()) :: :ok | {:error, term()}
  defp mux_audio(file_path, audio_url) do
    output_path = Path.join(Path.dirname(file_path), @muxed_name)

    File.rm(output_path)

    result =
      Lolek.Command.run(
        "ffmpeg",
        [
          "-y",
          "-i",
          file_path,
          "-i",
          audio_url,
          "-map",
          "0:v:0",
          "-map",
          "1:a:0",
          "-c:v",
          "copy",
          "-c:a",
          "aac",
          "-b:a",
          @audio_bitrate,
          "-movflags",
          "+faststart",
          # Do not use -shortest here: if TikTok serves an unexpectedly short
          # audio rendition, preserving the full video is less surprising than
          # cutting the clip to the audio length.
          output_path
        ],
        timeout: command_timeout(:convert_command_timeout_seconds)
      )

    with {:ok, _output} <- result,
         {:ok, %{video?: true, audio?: true}} <- media_streams(output_path),
         :ok <- replace_original(file_path, output_path) do
      Logger.info("Muxed TikTok audio into gallery video: #{file_path}")
      :ok
    else
      {:ok, streams} ->
        File.rm(output_path)
        {:error, {:muxed_file_missing_streams, streams}}

      {:error, reason} ->
        File.rm(output_path)
        {:error, reason}
    end
  end

  @spec replace_original(String.t(), String.t()) :: :ok | {:error, term()}
  defp replace_original(file_path, output_path) do
    with :ok <- File.rm(file_path),
         :ok <- File.rename(output_path, file_path) do
      :ok
    else
      {:error, reason} -> {:error, {:replace_muxed_file, reason}}
    end
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
