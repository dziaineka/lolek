defmodule Lolek.YoutubePostDownloader do
  @moduledoc """
  This module downloads media from YouTube community posts (/post/<id> URLs)
  by parsing the post page's embedded JSON data.
  """

  @hosts ["youtube.com", "www.youtube.com", "m.youtube.com"]
  @post_path_regex ~r{^/post/[A-Za-z0-9_-]+/?$}
  @yt_initial_data_regex ~r/ytInitialData\s*=\s*(\{.*?\});\s*<\/script>/s
  @downloaded_name "downloaded"
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

  @type media_item :: %{type: :image | :video, url: String.t()}
  @type http_response :: %{body: binary(), status: integer()}

  @spec download(String.t(), String.t()) ::
          {:ok, {:downloaded_media, String.t(), [String.t()]}} | {:error, term()}
  def download(url, output_path) do
    with :ok <- File.mkdir_p(output_path),
         {:ok, media_items} <- fetch_media_items(url),
         {:ok, files} <- download_media_files(media_items, output_path, @downloaded_name) do
      {:ok, {:downloaded_media, output_path, files}}
    end
  end

  @spec download_gallery(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def download_gallery(url, output_dir) do
    with :ok <- File.mkdir_p(output_dir),
         {:ok, media_items} <- fetch_media_items(url) do
      download_media_files(media_items, output_dir, nil)
    end
  end

  @spec caption(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def caption(url) do
    with {:ok, html_response} <- get(url) do
      extract_caption(html_response.body)
    end
  end

  @spec extract_post(binary()) :: {:ok, map()} | {:error, String.t()}
  def extract_post(body) do
    with [json] <- Regex.run(@yt_initial_data_regex, body, capture: :all_but_first),
         {:ok, data} when is_map(data) <- Jason.decode(json),
         {:ok, post} <- find_post(data) do
      {:ok, post}
    else
      _ -> {:error, "YouTube post data was not found"}
    end
  end

  @spec extract_media_items(binary()) :: {:ok, [media_item()]} | {:error, String.t()}
  def extract_media_items(body) do
    with {:ok, post} <- extract_post(body) do
      case collect_media_items(post) do
        [_ | _] = media_items -> {:ok, media_items}
        [] -> {:error, "YouTube post media was not found"}
      end
    end
  end

  @spec extract_caption(binary()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def extract_caption(body) do
    with {:ok, post} <- extract_post(body) do
      {:ok, post_caption(post)}
    end
  end

  @spec normalize_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} = uri
      when scheme in ["http", "https"] and host in @hosts and is_binary(path) ->
        if Regex.match?(@post_path_regex, path) do
          normalized_uri = %URI{
            uri
            | scheme: "https",
              host: "www.youtube.com",
              port: nil,
              path: String.trim_trailing(path, "/"),
              query: nil,
              fragment: nil
          }

          {:ok, URI.to_string(normalized_uri)}
        else
          {:error, "Unsupported YouTube post URL"}
        end

      _ ->
        {:error, "Unsupported YouTube post URL"}
    end
  end

  @spec fetch_media_items(String.t()) :: {:ok, [media_item()]} | {:error, term()}
  defp fetch_media_items(url) do
    with {:ok, html_response} <- get(url) do
      extract_media_items(html_response.body)
    end
  end

  @spec find_post(term()) :: {:ok, map()} | :error
  defp find_post(%{"backstagePostRenderer" => %{} = post}), do: {:ok, post}

  defp find_post(%{} = map) do
    map
    |> Map.values()
    |> find_post_in_values()
  end

  defp find_post(list) when is_list(list), do: find_post_in_values(list)
  defp find_post(_value), do: :error

  @spec find_post_in_values([term()]) :: {:ok, map()} | :error
  defp find_post_in_values(values) do
    Enum.reduce_while(values, :error, fn value, _acc ->
      case find_post(value) do
        {:ok, _} = found -> {:halt, found}
        :error -> {:cont, :error}
      end
    end)
  end

  @spec collect_media_items(term()) :: [media_item()]
  defp collect_media_items(%{"backstageVideoRenderer" => renderer}) do
    case Map.get(renderer, "videoId") do
      video_id when is_binary(video_id) and video_id != "" ->
        [%{type: :video, url: "https://www.youtube.com/watch?v=" <> video_id}]

      _ ->
        []
    end
  end

  defp collect_media_items(%{"postMultiImageRenderer" => %{"images" => images}})
       when is_list(images) do
    Enum.flat_map(images, &collect_media_items/1)
  end

  defp collect_media_items(%{
         "backstageImageRenderer" => %{"image" => %{"thumbnails" => thumbnails}}
       })
       when is_list(thumbnails) do
    case Enum.max_by(thumbnails, &Map.get(&1, "width", 0), fn -> nil end) do
      %{"url" => url} when is_binary(url) -> [%{type: :image, url: url}]
      _ -> []
    end
  end

  defp collect_media_items(%{} = map) do
    map |> Map.values() |> Enum.flat_map(&collect_media_items/1)
  end

  defp collect_media_items(list) when is_list(list) do
    Enum.flat_map(list, &collect_media_items/1)
  end

  defp collect_media_items(_value), do: []

  @spec post_caption(map()) :: String.t() | nil
  defp post_caption(%{"contentText" => %{"runs" => runs}}) when is_list(runs) do
    runs
    |> Enum.map_join(&Map.get(&1, "text", ""))
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp post_caption(_post), do: nil

  @spec download_media_files([media_item()], String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  defp download_media_files(media_items, output_dir, name_prefix) do
    media_items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {media_item, index}, {:ok, paths} ->
      output_stem = output_stem(output_dir, name_prefix, index)

      case download_media_item(media_item, output_stem) do
        {:ok, actual_path} -> {:cont, {:ok, paths ++ [actual_path]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "YouTube post media was not found"}
      result -> result
    end
  end

  @spec output_stem(String.t(), String.t() | nil, pos_integer()) :: String.t()
  defp output_stem(output_dir, nil, index),
    do: Path.join(output_dir, String.pad_leading("#{index}", 3, "0"))

  defp output_stem(output_dir, name_prefix, index),
    do: Path.join(output_dir, "#{name_prefix}_#{String.pad_leading("#{index}", 3, "0")}")

  @spec download_media_item(media_item(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp download_media_item(%{type: :image, url: url}, output_stem) do
    download_image(url, output_stem <> ".webp")
  end

  defp download_media_item(%{type: :video, url: url}, output_stem) do
    download_video(url, output_stem)
  end

  @spec download_image(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp download_image(url, output_file_path) do
    case Req.get(url,
           headers: image_headers(),
           max_redirects: 5,
           decode_body: false,
           into: File.stream!(output_file_path)
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, output_file_path}

      {:ok, %Req.Response{status: status}} ->
        _ = File.rm(output_file_path)
        {:error, "HTTP GET failed with status #{status}"}

      {:error, exception} ->
        _ = File.rm(output_file_path)
        {:error, format_error(exception)}
    end
  end

  @spec download_video(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp download_video(url, output_stem) do
    args =
      yt_dlp_cookies_args() ++
        [
          "--format-sort",
          "+vcodec:h264,+acodec:aac",
          "--remux-video",
          "mp4",
          "--max-filesize",
          max_download_file_size(),
          "--no-playlist",
          "-o",
          output_stem,
          url
        ]

    case Lolek.Command.run("yt-dlp", args, timeout: command_timeout()) do
      {:ok, _result} ->
        file_path = output_stem <> ".mp4"

        if File.exists?(file_path) do
          {:ok, file_path}
        else
          {:error, "yt-dlp produced no video file for YouTube post video"}
        end

      {:error, reason} ->
        {:error, {:yt_dlp, reason}}
    end
  end

  @spec get(String.t()) :: {:ok, http_response()} | {:error, String.t()}
  defp get(url) do
    with {:ok, normalized_url} <- normalize_url(url) do
      case Req.get(normalized_url,
             headers: [{"user-agent", @user_agent}],
             max_redirects: 5
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, %{status: status, body: to_string(body)}}

        {:ok, %Req.Response{status: status}} ->
          {:error, "HTTP GET failed with status #{status}"}

        {:error, exception} ->
          {:error, format_error(exception)}
      end
    end
  end

  @spec image_headers() :: [{String.t(), String.t()}]
  defp image_headers do
    [
      {"user-agent", @user_agent},
      {"accept", "image/avif,image/webp,image/*,*/*;q=0.8"}
    ]
  end

  @spec yt_dlp_cookies_args() :: [String.t()]
  defp yt_dlp_cookies_args do
    case Application.fetch_env!(:lolek, :yt_dlp_cookies_file) do
      path when is_binary(path) ->
        writable = Path.join(System.tmp_dir!(), "yt_dlp_cookies.txt")
        unless File.exists?(writable), do: File.copy!(path, writable)
        ["--cookies", writable]

      nil ->
        []
    end
  end

  @spec max_download_file_size() :: String.t()
  defp max_download_file_size do
    :lolek
    |> Application.fetch_env!(:max_file_size_to_compress)
    |> to_string()
  end

  @spec command_timeout() :: pos_integer()
  defp command_timeout do
    :lolek
    |> Application.fetch_env!(:download_command_timeout_seconds)
    |> :timer.seconds()
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)
end
