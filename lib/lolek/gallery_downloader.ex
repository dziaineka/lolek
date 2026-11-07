defmodule Lolek.GalleryDownloader do
  @moduledoc """
  Downloads images and GIFs from social media URLs using gallery-dl.
  """
  require Logger

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
    with_cookies_fallback(
      &run_gallery_dl(url, output_dir, &1),
      fn _reason -> true end
    )
  end

  @spec run_gallery_dl(String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  defp run_gallery_dl(url, output_dir, cookies_args) do
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
          cookies_args ++
          config_args() ++
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
  downloaders can still try to get the media. When `info_json_path` is given, the
  post metadata is written to this file for `Lolek.Post.GalleryDl`.
  """
  @spec fetch_text_post(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def fetch_text_post(url, info_json_path \\ nil) do
    case with_cookies_fallback(
           &text_post_with_metadata(url, &1),
           &(&1 not in [:post_has_media, :no_text_post])
         ) do
      {:ok, {text, metadata}} ->
        _ = write_info_json(metadata, info_json_path)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec text_post_with_metadata(String.t(), [String.t()]) ::
          {:ok, {String.t(), map() | nil}} | {:error, term()}
  defp text_post_with_metadata(url, cookies_args) do
    case dump_json(url, cookies_args) do
      {:ok, output} ->
        with {:ok, text} <- parse_text_post(output) do
          {:ok, {text, directory_metadata(output)}}
        end

      {:error, reason} ->
        {:error, {:gallery_dl_text_post, reason}}
    end
  end

  @spec directory_metadata(String.t()) :: map() | nil
  defp directory_metadata(output) do
    case Jason.decode(output) do
      {:ok, messages} when is_list(messages) ->
        Enum.find_value(messages, fn
          [2, %{} = metadata] -> metadata
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  @spec write_info_json(map() | nil, String.t() | nil) :: :ok | {:error, term()}
  defp write_info_json(nil, _info_json_path), do: :ok
  defp write_info_json(_metadata, nil), do: :ok

  defp write_info_json(metadata, info_json_path) do
    with :ok <- File.mkdir_p(Path.dirname(info_json_path)) do
      File.write(info_json_path, Jason.encode!(metadata))
    end
  end

  @doc """
  Reads the metadata messages of a post (`gallery-dl --dump-json`) without a download.
  `options` are more gallery-dl `-o` options, like `"extractor.twitter.quoted=true"`.
  """
  @spec fetch_metadata(String.t(), [String.t()]) :: {:ok, list()} | {:error, term()}
  def fetch_metadata(url, options \\ []) do
    option_args = Enum.flat_map(options, &["-o", &1])

    with_cookies_fallback(
      fn cookies_args ->
        # gallery-dl reports some failures as an error message with exit status 0.
        with {:ok, output} <- dump_json(url, option_args ++ cookies_args),
             {:ok, messages} when is_list(messages) <- Jason.decode(output),
             nil <- Enum.find_value(messages, &error_message/1) do
          {:ok, messages}
        else
          {:gallery_dl_error, error} -> {:error, {:gallery_dl_error, error}}
          {:ok, _other} -> {:error, :invalid_gallery_dl_output}
          {:error, %Jason.DecodeError{}} -> {:error, :invalid_gallery_dl_output}
          {:error, reason} -> {:error, {:gallery_dl_metadata, reason}}
        end
      end,
      fn _reason -> true end
    )
  end

  @spec dump_json(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp dump_json(url, cookies_args) do
    case Lolek.Command.run(
           "gallery-dl",
           ["--dump-json", "-o", "extractor.twitter.text-tweets=true"] ++
             cookies_args ++ config_args() ++ [url],
           timeout: command_timeout()
         ) do
      {:ok, output} -> {:ok, output |> Keyword.get(:stdout, []) |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, reason}
    end
  end

  # Logged-in gallery-dl requests can fail where guest requests work. For
  # example, the Twitter/X client transaction step can fail for logged-in
  # sessions only. Thus a failed run with cookies is tried again without them.
  @spec with_cookies_fallback(
          ([String.t()] -> :ok | {:ok, term()} | {:error, term()}),
          (term() -> boolean())
        ) :: :ok | {:ok, term()} | {:error, term()}
  defp with_cookies_fallback(fun, retry?) do
    case cookies_args() do
      [] -> fun.([])
      cookies_args -> fun |> apply([cookies_args]) |> retry_without_cookies(fun, retry?)
    end
  end

  @spec retry_without_cookies(
          :ok | {:ok, term()} | {:error, term()},
          ([String.t()] -> :ok | {:ok, term()} | {:error, term()}),
          (term() -> boolean())
        ) :: :ok | {:ok, term()} | {:error, term()}
  defp retry_without_cookies({:error, reason} = error, fun, retry?) do
    if retry?.(reason) do
      Logger.info("gallery-dl failed with cookies, trying again without cookies")
      fun.([])
    else
      error
    end
  end

  defp retry_without_cookies(result, _fun, _retry?), do: result

  @spec parse_text_post(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_text_post(output) do
    with {:ok, messages} when is_list(messages) <- Jason.decode(output),
         nil <- Enum.find_value(messages, &error_message/1),
         false <- Enum.any?(messages, &media_message?/1),
         {:ok, text} <- Enum.find_value(messages, {:error, :no_text_post}, &message_text/1) do
      {:ok, text}
    else
      true -> {:error, :post_has_media}
      {:gallery_dl_error, error} -> {:error, {:gallery_dl_error, error}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_gallery_dl_output}
    end
  end

  @spec error_message(term()) :: {:gallery_dl_error, term()} | nil
  defp error_message([-1, error]), do: {:gallery_dl_error, error}
  defp error_message(_message), do: nil

  # gallery-dl message types: -1 is an error, 2 is a post directory, 3 is a media URL,
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

  @spec cookies_args() :: [String.t()]
  defp cookies_args do
    case Application.fetch_env!(:lolek, :gallery_dl_cookies_file) do
      path when is_binary(path) -> ["--cookies", path]
      nil -> []
    end
  end

  @spec config_args() :: [String.t()]
  defp config_args do
    case Application.fetch_env!(:lolek, :gallery_dl_config_file) do
      path when is_binary(path) -> ["--config", path]
      nil -> []
    end
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
