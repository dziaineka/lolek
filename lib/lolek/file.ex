defmodule Lolek.File do
  @moduledoc """
  This module is responsible for file operations.
  """
  require Logger

  @ready_to_telegram "ready_to_telegram"
  @compressed_name "compressed.mp4"
  @downloaded_name "downloaded"
  @gallery_subdir "gallery"
  @media_manifest "media_manifest.json"
  @legacy_gallery_manifest "gallery_manifest.json"

  @type ready_media_entry :: {tg_file_id :: String.t(), ext :: String.t()}
  @type sent_media_entry :: {ext :: String.t(), tg_file_id :: String.t()}

  @type file_state ::
          {:ready_media, [ready_media_entry()]}
          | {:downloaded_media, cache_root :: String.t(), files :: [String.t()]}
          | {:prepared_media, cache_root :: String.t(), files :: [String.t()]}
          | {:new_file, String.t()}
          | {:sent_media, cache_root :: String.t(), [sent_media_entry()]}

  @spec get_video_width_and_height(String.t()) :: :error | {:ok, {integer(), integer()}}
  def get_video_width_and_height(file_path) do
    case Lolek.Command.run(
           "ffprobe",
           [
             "-v",
             "error",
             "-select_streams",
             "v",
             "-show_entries",
             "stream=width,height",
             "-of",
             "csv=p=0:s=x",
             file_path
           ],
           timeout: command_timeout(:probe_command_timeout_seconds)
         ) do
      {:ok, result} ->
        # Extract stdout regardless of stderr warnings
        stdout_data = Keyword.get(result, :stdout, [])
        dimensions = stdout_data |> IO.iodata_to_binary() |> String.trim()

        case Regex.run(~r/(\d+)x(\d+)/, dimensions) do
          [_, width_str, height_str] ->
            width = String.to_integer(width_str)
            height = String.to_integer(height_str)
            {:ok, {width, height}}

          nil ->
            Logger.warning(
              "Could not parse dimensions from ffprobe output: #{inspect(dimensions)}"
            )

            :error
        end

      {:error, reason} ->
        Logger.warning("Error running ffprobe: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Exception when getting video dimensions: #{inspect(error)}")
      :error
  end

  @spec get_video_duration(String.t()) :: :error | {:ok, integer()}
  def get_video_duration(file_path) do
    case Lolek.Command.run(
           "ffprobe",
           [
             "-v",
             "error",
             "-show_entries",
             "stream=codec_type,duration:format=duration",
             "-of",
             "json",
             file_path
           ],
           timeout: command_timeout(:probe_command_timeout_seconds)
         ) do
      {:ok, result} ->
        # Extract stdout regardless of stderr warnings
        stdout_data = Keyword.get(result, :stdout, [])
        raw_probe = stdout_data |> IO.iodata_to_binary() |> String.trim()

        case parse_video_duration(raw_probe) do
          {:ok, duration} ->
            {:ok, duration}

          :error ->
            Logger.warning("Could not parse duration from ffprobe output: #{inspect(raw_probe)}")

            :error
        end

      {:error, reason} ->
        Logger.warning("Error when determining duration: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Exception when determining duration: #{inspect(error)}")
      :error
  end

  @spec parse_video_duration(String.t()) :: :error | {:ok, integer()}
  defp parse_video_duration(raw_probe) do
    case Jason.decode(raw_probe) do
      {:ok, probe} when is_map(probe) ->
        format_duration =
          probe
          |> Map.get("format", %{})
          |> Map.get("duration")

        [
          first_stream_duration(probe, "video"),
          format_duration,
          first_stream_duration(probe, "audio")
        ]
        |> Enum.find_value(:error, &parse_duration/1)

      _ ->
        :error
    end
  end

  @spec first_stream_duration(map(), String.t()) :: nil | String.t()
  defp first_stream_duration(probe, codec_type) do
    probe
    |> Map.get("streams", [])
    |> Enum.find(&(Map.get(&1, "codec_type") == codec_type))
    |> case do
      %{"duration" => duration} -> duration
      _ -> nil
    end
  end

  @spec parse_duration(term()) :: nil | {:ok, integer()}
  defp parse_duration(raw_duration) when is_binary(raw_duration) do
    case Float.parse(raw_duration) do
      {duration_float, _} -> {:ok, round(duration_float)}
      :error -> nil
    end
  end

  defp parse_duration(_raw_duration), do: nil

  @spec get_file_path_by_pattern(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_file_path_by_pattern(output_path, pattern) do
    case File.ls(output_path) do
      {:ok, files} -> files
      _ -> []
    end
    |> Enum.find(:not_found, fn file_name -> String.contains?(file_name, pattern) end)
    |> case do
      :not_found -> {:error, "File not found"}
      file_name -> {:ok, Path.join(output_path, file_name)}
    end
  end

  @spec file_size(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec move_to_ready_to_telegram(Lolek.File.file_state()) :: :ok | {:error, term()}
  def move_to_ready_to_telegram({:sent_media, cache_root, entries}) do
    ready_path = Path.join(cache_root, @ready_to_telegram)
    manifest_path = Path.join(ready_path, @media_manifest)

    manifest =
      Enum.map(entries, fn {ext, file_id} ->
        %{"file_id" => file_id, "ext" => ext}
      end)

    with :ok <- File.mkdir_p(ready_path) do
      case File.write(manifest_path, Jason.encode!(manifest)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:media_manifest_write, reason}}
      end
    end
  end

  def move_to_ready_to_telegram(_another_file_state) do
    :ok
  end

  @spec get_folder_path(String.t()) :: {:ok, String.t()}
  def get_folder_path(url) do
    download_path = Application.fetch_env!(:lolek, :download_path)
    folder_name = Lolek.Url.to_folder_name(url)
    {:ok, Path.join(download_path, folder_name)}
  end

  @spec get_file_state(String.t()) :: {:ok, Lolek.File.file_state()}
  def get_file_state(folder_path) do
    with :not_ready <- check_if_ready_to_tg(folder_path),
         :not_compressed <- check_if_compressed(folder_path),
         :not_downloaded <- check_if_downloaded(folder_path),
         :not_gallery <- check_if_gallery(folder_path) do
      {:ok, {:new_file, folder_path}}
    else
      {:exists, state} ->
        {:ok, state}
    end
  end

  @spec check_if_ready_to_tg(String.t()) :: :not_ready | {:exists, Lolek.File.file_state()}
  defp check_if_ready_to_tg(folder_path) do
    ready_to_telegram_path = Path.join(folder_path, @ready_to_telegram)

    manifest_paths = [
      Path.join(ready_to_telegram_path, @media_manifest),
      Path.join(ready_to_telegram_path, @legacy_gallery_manifest)
    ]

    case read_media_manifests(manifest_paths) do
      {:ok, [_ | _] = entries} -> {:exists, {:ready_media, entries}}
      _ -> check_single_file_cache(ready_to_telegram_path)
    end
  end

  @spec read_media_manifests([String.t()]) ::
          {:ok, [ready_media_entry()]} | {:error, term()}
  defp read_media_manifests([]), do: {:error, :enoent}

  defp read_media_manifests([manifest_path | remaining]) do
    case read_media_manifest(manifest_path) do
      {:ok, [_ | _] = entries} -> {:ok, entries}
      _ -> read_media_manifests(remaining)
    end
  end

  @spec check_single_file_cache(String.t()) :: :not_ready | {:exists, Lolek.File.file_state()}
  defp check_single_file_cache(ready_to_telegram_path) do
    case File.ls(ready_to_telegram_path) do
      {:ok, file_names} ->
        Enum.find_value(file_names, :not_ready, fn file_name ->
          file_path = Path.join(ready_to_telegram_path, file_name)
          check_cache_file(file_path)
        end)

      _ ->
        :not_ready
    end
  end

  @spec read_media_manifest(String.t()) ::
          {:ok, [ready_media_entry()]} | {:error, term()}
  defp read_media_manifest(manifest_path) do
    with {:ok, content} <- File.read(manifest_path),
         {:ok, entries} when is_list(entries) <- Jason.decode(content) do
      parsed =
        Enum.flat_map(entries, fn
          %{"file_id" => fid, "ext" => ext} when is_binary(fid) and is_binary(ext) ->
            [{fid, ext}]

          _ ->
            []
        end)

      {:ok, parsed}
    end
  end

  @spec check_if_gallery(String.t()) :: :not_gallery | {:exists, Lolek.File.file_state()}
  defp check_if_gallery(folder_path) do
    gallery_dir = Path.join(folder_path, @gallery_subdir)

    case Lolek.GalleryDownloader.list_media_files(gallery_dir) do
      [] -> :not_gallery
      files -> {:exists, {:downloaded_media, folder_path, files}}
    end
  end

  @spec check_cache_file(String.t()) :: {:exists, file_state()} | false
  defp check_cache_file(file_path) do
    if Path.basename(file_path) in [@media_manifest, @legacy_gallery_manifest] do
      false
    else
      check_single_cache_media(file_path)
    end
  end

  @spec check_single_cache_media(String.t()) :: {:exists, file_state()} | false
  defp check_single_cache_media(file_path) do
    if usable_cached_file?(file_path) do
      ext = file_path |> Path.extname() |> String.downcase()
      file_id = Path.basename(file_path, ext)
      {:exists, {:ready_media, [{file_id, ext}]}}
    else
      remove_invalid_cache_file(file_path)
      false
    end
  end

  @spec check_if_compressed(String.t()) :: :not_compressed | {:exists, Lolek.File.file_state()}
  defp check_if_compressed(folder_path) do
    file_path = Path.join(folder_path, @compressed_name)

    max_file_size_to_send_to_telegram =
      Application.fetch_env!(:lolek, :max_file_size_to_send_to_telegram)

    cond do
      not File.exists?(file_path) ->
        :not_compressed

      oversized_file?(file_path, max_file_size_to_send_to_telegram) ->
        remove_invalid_cache_file(file_path)
        :not_compressed

      not usable_cached_file?(file_path) ->
        remove_invalid_cache_file(file_path)
        :not_compressed

      true ->
        {
          :exists,
          {:prepared_media, folder_path, [file_path]}
        }
    end
  end

  @spec usable_cached_file?(String.t()) :: boolean()
  defp usable_cached_file?(file_path) do
    case file_size(file_path) do
      {:ok, size} when size > 0 -> usable_media_file?(file_path)
      _ -> false
    end
  end

  @spec usable_media_file?(String.t()) :: boolean()
  defp usable_media_file?(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".mp4" ->
        match?({:ok, duration} when duration > 0, get_video_duration(file_path))

      _ ->
        true
    end
  end

  @spec remove_invalid_cache_file(String.t()) :: :ok
  defp remove_invalid_cache_file(file_path) do
    Logger.warning("Removing invalid cached file: #{file_path}")
    File.rm(file_path)
    :ok
  end

  @spec oversized_file?(String.t(), non_neg_integer()) :: boolean()
  defp oversized_file?(file_path, max_size) do
    case file_size(file_path) do
      {:ok, size} -> size > max_size
      {:error, _} -> false
    end
  end

  @spec check_if_downloaded(String.t()) :: :not_downloaded | {:exists, Lolek.File.file_state()}
  defp check_if_downloaded(folder_path) do
    case get_file_path_by_pattern(folder_path, @downloaded_name) do
      {:ok, file_path} ->
        {
          :exists,
          {:downloaded_media, folder_path, [file_path]}
        }

      _ ->
        :not_downloaded
    end
  end

  @spec command_timeout(atom()) :: pos_integer()
  defp command_timeout(config_key) do
    :lolek
    |> Application.fetch_env!(config_key)
    |> :timer.seconds()
  end
end
