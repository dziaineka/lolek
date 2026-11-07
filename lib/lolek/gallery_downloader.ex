defmodule Lolek.GalleryDownloader do
  @moduledoc """
  Downloads images and GIFs from social media URLs using gallery-dl.
  """

  @image_extensions ~w(.jpg .jpeg .png .gif .webp .avif .heic .heif)
  @video_extensions ~w(.mp4 .mkv .webm .mov .m4v)
  # Twitter/X keeps the post text in "content", Bluesky in "text".
  @text_post_fields ~w(content text description)

  @spec download(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def download(url, output_dir) do
    with :ok <- File.mkdir_p(output_dir),
         :ok <- run_gallery_dl(url, output_dir) do
      repaired_media_files(output_dir)
    end
  end

  @spec run_gallery_dl(String.t(), String.t()) :: :ok | {:error, term()}
  defp run_gallery_dl(url, output_dir) do
    result =
      Lolek.Command.run(
        "gallery-dl",
        [
          "--no-part",
          "--quiet",
          "--write-info-json",
          "--range",
          "1-#{max_gallery_media()}",
          "-o",
          "extractor.ytdl.enabled=true",
          "-o",
          "extractor.ytdl.module=yt_dlp"
        ] ++
          extra_args() ++
          [
            "--dest",
            output_dir,
            url
          ],
        timeout: command_timeout()
      )

    case result do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:gallery_dl, reason}}
    end
  end

  @doc """
  Reads the text of a post without media, like a text-only tweet or Bluesky post.

  Returns an error when gallery-dl reports media for the post, so that other
  downloaders can still try to get the media.
  """
  @spec fetch_text_post(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_text_post(url) do
    result =
      Lolek.Command.run(
        "gallery-dl",
        ["--dump-json", "-o", "extractor.twitter.text-tweets=true"] ++ extra_args() ++ [url],
        timeout: command_timeout()
      )

    case result do
      {:ok, output} ->
        output
        |> Keyword.get(:stdout, [])
        |> IO.iodata_to_binary()
        |> parse_text_post()

      {:error, reason} ->
        {:error, {:gallery_dl_text_post, reason}}
    end
  end

  @spec parse_text_post(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_text_post(output) do
    with {:ok, messages} when is_list(messages) <- Jason.decode(output),
         false <- Enum.any?(messages, &media_message?/1),
         {:ok, text} <- Enum.find_value(messages, {:error, :no_text_post}, &message_text/1) do
      {:ok, text}
    else
      true -> {:error, :post_has_media}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_gallery_dl_output}
    end
  end

  # gallery-dl message types: 2 is a post directory, 3 is a media URL,
  # 6 is a URL for another extractor.
  @spec media_message?(term()) :: boolean()
  defp media_message?([type | _]) when type in [3, 6], do: true
  defp media_message?(_message), do: false

  @spec message_text(term()) :: {:ok, String.t()} | nil
  defp message_text([2, %{} = metadata]) do
    with {:ok, text} <- Enum.find_value(@text_post_fields, &extract_text_field(metadata, &1)) do
      text
      |> String.replace(["\r\n", "\r"], "\n")
      |> String.trim()
      |> case do
        "" -> nil
        text -> {:ok, text}
      end
    end
  end

  defp message_text(_message), do: nil

  @spec repaired_media_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp repaired_media_files(output_dir) do
    files = list_media_files(output_dir)

    with :ok <- repair_single_gallery_video(output_dir, files) do
      {:ok, files}
    end
  end

  @spec list_media_files(String.t()) :: [String.t()]
  def list_media_files(dir) do
    dir
    |> collect_files()
    |> Enum.filter(&(image_file?(&1) or video_file?(&1)))
    |> Enum.sort()
    |> Enum.take(max_gallery_media())
  end

  @spec video_file?(String.t()) :: boolean()
  def video_file?(path) do
    path |> Path.extname() |> String.downcase() |> then(&(&1 in @video_extensions))
  end

  @spec repair_single_gallery_video(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp repair_single_gallery_video(gallery_dir, files) do
    {videos, images} = Enum.split_with(files, &video_file?/1)
    mp4_videos = Enum.filter(videos, fn p -> Path.extname(p) |> String.downcase() == ".mp4" end)

    case {images, mp4_videos} do
      {[], [file_path]} ->
        # gallery-dl may keep adaptive TikTok audio in JSON sidecars while
        # writing only the video stream to disk. Repair that gallery-dl output
        # in place before the generic downloader routing promotes the MP4.
        Lolek.TiktokAudioMuxer.maybe_mux(gallery_dir, file_path)

      _ ->
        :ok
    end
  end

  @spec read_caption(String.t()) :: {:ok, String.t()} | :error
  def read_caption(gallery_dir) do
    gallery_dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.find_value(:error, &read_caption_from_json/1)
  end

  @spec collect_files(String.t()) :: [String.t()]
  defp collect_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &collect_entry(dir, &1))
      {:error, _} -> []
    end
  end

  @spec collect_entry(String.t(), String.t()) :: [String.t()]
  defp collect_entry(dir, entry) do
    path = Path.join(dir, entry)
    if File.dir?(path), do: collect_files(path), else: [path]
  end

  @spec image_file?(String.t()) :: boolean()
  def image_file?(path) do
    path |> Path.extname() |> String.downcase() |> then(&(&1 in @image_extensions))
  end

  @spec read_caption_from_json(String.t()) :: {:ok, String.t()} | nil
  defp read_caption_from_json(json_path) do
    with {:ok, content} <- File.read(json_path),
         {:ok, data} when is_map(data) <- Jason.decode(content) do
      Enum.find_value(["content", "description", "title"], &extract_text_field(data, &1))
    else
      _ -> nil
    end
  end

  @spec extract_text_field(map(), String.t()) :: {:ok, String.t()} | nil
  defp extract_text_field(data, field) do
    case Map.get(data, field) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> nil
    end
  end

  @spec extra_args() :: [String.t()]
  defp extra_args do
    cookies =
      case Application.fetch_env!(:lolek, :gallery_dl_cookies_file) do
        path when is_binary(path) -> ["--cookies", path]
        nil -> []
      end

    config_file =
      case Application.fetch_env!(:lolek, :gallery_dl_config_file) do
        path when is_binary(path) -> ["--config", path]
        nil -> []
      end

    cookies ++ config_file
  end

  @spec command_timeout() :: pos_integer()
  defp command_timeout do
    :lolek
    |> Application.fetch_env!(:download_command_timeout_seconds)
    |> :timer.seconds()
  end

  @spec max_gallery_media() :: pos_integer()
  defp max_gallery_media do
    Application.fetch_env!(:lolek, :max_gallery_media)
  end
end
