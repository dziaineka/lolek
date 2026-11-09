defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024
  @max_upload_file_name_bytes 180
  @flood_wait_attempts 2
  @max_flood_wait_ms 60_000

  @typep media_source :: {:file_path, String.t()} | {:file_id, String.t()}
  @typep media_item :: {media_source(), String.t()}

  require Logger

  @spec send_file(integer(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, file_state), do: send_file(chat_id, file_state, [])

  @spec send_file(integer(), Lolek.File.file_state(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, {:prepared_media, cache_root, files} = file_state, context) do
    case path_media_items(files) do
      [] ->
        {:error, :no_usable_media_files}

      items ->
        case send_rich_post(chat_id, items, context, details?()) do
          {:ok, entries} when length(entries) == length(items) ->
            {:ok, {:sent_media, cache_root, entries}}

          # The post reached the chat, but the file_ids are not known. The files stay
          # in the cache, so the next request uploads them again.
          {:ok, _entries} ->
            {:ok, file_state}

          {:error, _reason} = error ->
            error
        end
    end
  end

  def send_file(chat_id, {:ready_media, entries}, context) do
    limited_entries = Enum.take(entries, max_gallery_media())
    items = Enum.map(limited_entries, fn {file_id, ext} -> {{:file_id, file_id}, ext} end)

    with {:ok, _sent_entries} <- send_rich_post(chat_id, items, context, details?()) do
      {:ok, {:ready_media, limited_entries}}
    end
  end

  def send_file(chat_id, {:text_post, _cache_root, text} = file_state, context) do
    post = Keyword.get(context, :post) || %Lolek.Post{}
    post = if is_nil(post.text), do: %{post | text: text, facets: nil}, else: post

    with {:ok, _entries} <- send_rich_post(chat_id, [], Keyword.put(context, :post, post), true) do
      {:ok, file_state}
    end
  end

  @spec path_media_items([String.t()]) :: [media_item()]
  defp path_media_items(files) do
    files
    |> Enum.take(max_gallery_media())
    |> Enum.map(fn file_path ->
      {{:file_path, file_path}, file_path |> Path.extname() |> String.downcase()}
    end)
  end

  @spec details?() :: boolean()
  defp details?, do: Application.fetch_env!(:lolek, :post_source_caption)

  # Sends one rich message with all media items and returns the `{ext, file_id}` entries
  # of the uploaded media in the order of the items.
  @spec send_rich_post(integer(), [media_item()], keyword(), boolean()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_rich_post(chat_id, items, context, details?) do
    items = visual_media_first(items)
    post = Keyword.get(context, :post)
    build_opts = [details: details?, requester: requester_caption(context)]
    options = send_options(items, context)

    result =
      with_media_sources(Enum.map(items, &elem(&1, 0)), context, fn sources ->
        media = rich_media(items, sources)

        send_with_remote_media_fallback(
          post,
          build_opts,
          &send_rich_message(chat_id, post, media, &1, options)
        )
      end)

    case result do
      {:ok, {%ExGram.Model.Message{} = message, used_opts}} ->
        entries = extract_file_entries(items, message, post, used_opts)
        refresh_after_send(chat_id, message, post, items, entries, used_opts, context)

        Lolek.PrivateMedia.attach(
          chat_id,
          message.message_id,
          entries,
          Keyword.get(context, :private_media_bot_username)
        )

        {:ok, entries}

      {:ok, {other, _used_opts}} ->
        {:error, {:unexpected_telegram_response, other}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec send_rich_message(
          integer(),
          Lolek.Post.t() | nil,
          [Lolek.RichPost.media()],
          keyword(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  defp send_rich_message(chat_id, post, media, build_opts, options) do
    {rich_message, _media_indexes} = Lolek.RichPost.build(post, media, build_opts)
    call_telegram(fn -> Lolek.Telegram.send_rich_message(chat_id, rich_message, options) end)
  end

  # Telegram downloads the media of quoted posts by URL. When this fails, the post is
  # sent again without them.
  @spec send_with_remote_media_fallback(
          Lolek.Post.t() | nil,
          keyword(),
          (keyword() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, {term(), keyword()}} | {:error, term()}
  defp send_with_remote_media_fallback(post, build_opts, send_fun) do
    case send_fun.(build_opts) do
      {:ok, response} ->
        {:ok, {response, build_opts}}

      {:error, {:telegram_api, %ExGram.Error{code: 400} = error}} = failure ->
        if remote_media?(post),
          do: retry_without_remote_media(build_opts, send_fun, error),
          else: failure

      {:error, _reason} = error ->
        error
    end
  end

  @spec retry_without_remote_media(
          keyword(),
          (keyword() -> {:ok, term()} | {:error, term()}),
          ExGram.Error.t()
        ) :: {:ok, {term(), keyword()}} | {:error, term()}
  defp retry_without_remote_media(build_opts, send_fun, error) do
    Logger.warning(
      "Telegram rejected the rich message, sending it without linked media; " <>
        "reason: #{inspect(error.message)}"
    )

    fallback_opts = Keyword.put(build_opts, :remote_media, false)

    with {:ok, response} <- send_fun.(fallback_opts) do
      {:ok, {response, fallback_opts}}
    end
  end

  @spec remote_media?(Lolek.Post.t() | nil) :: boolean()
  defp remote_media?(%Lolek.Post{quoted: quoted, reply_to: reply_to}) do
    Enum.any?([quoted, reply_to], &match?(%Lolek.Post{media: [_ | _]}, &1))
  end

  defp remote_media?(nil), do: false

  @spec rich_media([media_item()], [term()]) :: [Lolek.RichPost.media()]
  defp rich_media(items, sources) do
    items
    |> Enum.zip(sources)
    |> Enum.map(fn {{source, ext}, prepared_source} ->
      %{source: prepared_source, ext: ext, options: media_options(source, ext)}
    end)
  end

  @spec media_options(media_source(), String.t()) :: keyword()
  defp media_options({:file_path, file_path}, ext) do
    if Lolek.GalleryDownloader.video_file?("x#{ext}"), do: video_options(file_path), else: []
  end

  defp media_options({:file_id, _file_id}, _ext), do: []

  @spec send_options([media_item()], keyword()) :: keyword()
  defp send_options(items, context) do
    options =
      if Enum.any?(items, fn {_source, ext} -> Lolek.GalleryDownloader.video_file?("x#{ext}") end),
         do: [disable_notification: true],
         else: []

    add_message_thread_id(options, context)
  end

  @spec max_gallery_media() :: pos_integer()
  defp max_gallery_media do
    Application.fetch_env!(:lolek, :max_gallery_media)
  end

  # The rich message shows other files after the visual media, so the items take the
  # same order. Then the file_ids of the response match the items.
  @spec visual_media_first([media_item()]) :: [media_item()]
  defp visual_media_first(items) do
    {visual, other} =
      Enum.split_with(items, fn {_source, ext} -> Lolek.RichPost.visual_media?(ext) end)

    visual ++ other
  end

  @spec extract_file_entries(
          [media_item()],
          ExGram.Model.Message.t(),
          Lolek.Post.t() | nil,
          keyword()
        ) :: [{String.t(), String.t()}]
  defp extract_file_entries([], _message, _post, _build_opts), do: []

  defp extract_file_entries(items, %ExGram.Model.Message{} = message, post, build_opts) do
    # The block positions do not depend on the media sources.
    placeholders = Enum.map(items, fn {_source, ext} -> %{source: nil, ext: ext, options: []} end)
    {_rich_message, media_indexes} = Lolek.RichPost.build(post, placeholders, build_opts)

    file_ids =
      case message.rich_message do
        %ExGram.Model.RichMessage{blocks: blocks} when is_list(blocks) ->
          Lolek.RichPost.file_ids(blocks, media_indexes)

        _ ->
          []
      end

    if length(file_ids) == length(items) do
      items
      |> Enum.zip(file_ids)
      |> Enum.map(fn {{_source, ext}, file_id} -> {ext, file_id} end)
    else
      Logger.warning(
        "Rich message has #{length(file_ids)} media files, expected #{length(items)}; " <>
          "the file_ids are not cached"
      )

      []
    end
  end

  # The "processed in" time is known only after the upload, so the message is edited
  # with the final time. The edit uses the new file_ids and does not upload again.
  @spec refresh_after_send(
          integer(),
          ExGram.Model.Message.t(),
          Lolek.Post.t() | nil,
          [media_item()],
          [{String.t(), String.t()}],
          keyword(),
          keyword()
        ) :: :ok
  defp refresh_after_send(chat_id, message, post, items, entries, build_opts, context) do
    with %ExGram.Model.Message{message_id: message_id} when is_integer(message_id) <- message,
         requester when is_binary(requester) <- requester_caption(context),
         {:ok, media} <- refreshed_media(items, entries) do
      {rich_message, _media_indexes} =
        Lolek.RichPost.build(post, media, Keyword.put(build_opts, :requester, requester))

      edit_rich_message(chat_id, message_id, rich_message)
    end

    :ok
  end

  @spec edit_rich_message(integer(), integer(), ExGram.Model.InputRichMessage.t()) :: :ok
  defp edit_rich_message(chat_id, message_id, rich_message) do
    case call_telegram(fn ->
           Lolek.Telegram.edit_message_text(chat_id, message_id, rich_message: rich_message)
         end) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not update the Telegram message; reason: #{inspect(reason)}")
    end
  end

  @spec refreshed_media([media_item()], [{String.t(), String.t()}]) ::
          {:ok, [Lolek.RichPost.media()]} | :error
  defp refreshed_media([], _entries), do: {:ok, []}

  defp refreshed_media(items, entries) when length(items) == length(entries) do
    {:ok,
     items
     |> Enum.zip(entries)
     |> Enum.map(fn {{source, ext}, {_ext, file_id}} ->
       %{source: file_id, ext: ext, options: media_options(source, ext)}
     end)}
  end

  defp refreshed_media(_items, _entries), do: :error

  @spec with_media_sources([media_source()], keyword(), ([term()] -> term())) :: term()
  defp with_media_sources(sources, context, fun) do
    case prepare_media_sources(sources, context) do
      {:ok, prepared_sources, cleanups} ->
        try do
          fun.(prepared_sources)
        after
          cleanup_upload_files(cleanups)
        end

      {:error, reason, cleanups} ->
        cleanup_upload_files(cleanups)
        {:error, reason}
    end
  end

  @spec prepare_media_sources([media_source()], keyword()) ::
          {:ok, [term()], [(-> :ok)]} | {:error, term(), [(-> :ok)]}
  defp prepare_media_sources(sources, context) do
    Enum.reduce_while(sources, {:ok, [], []}, fn source, {:ok, prepared, cleanups} ->
      case prepare_media_source(source, context) do
        {:ok, prepared_source, cleanup} ->
          {:cont, {:ok, [prepared_source | prepared], [cleanup | cleanups]}}

        {:error, reason} ->
          {:halt, {:error, reason, cleanups}}
      end
    end)
    |> case do
      {:ok, prepared, cleanups} -> {:ok, Enum.reverse(prepared), cleanups}
      error -> error
    end
  end

  @spec prepare_media_source(media_source(), keyword()) ::
          {:ok, term(), (-> :ok)} | {:error, term()}
  defp prepare_media_source({:file_path, file_path}, context), do: upload_file(file_path, context)
  defp prepare_media_source({:file_id, file_id}, _context), do: {:ok, file_id, fn -> :ok end}

  @spec cleanup_upload_files([(-> :ok)]) :: :ok
  defp cleanup_upload_files(cleanups) do
    Enum.each(cleanups, & &1.())
  end

  @spec upload_file(String.t(), keyword()) ::
          {:ok, {:file_content, File.Stream.t(), String.t()} | String.t(), (-> :ok)}
          | {:error, term()}
  defp upload_file(file_path, context) do
    if Application.fetch_env!(:lolek, :telegram_local_file_uploads) do
      local_upload_file(file_path, context)
    else
      {:ok,
       {:file_content, File.stream!(file_path, @upload_chunk_size, []),
        upload_file_name(file_path, context)}, fn -> :ok end}
    end
  end

  @spec local_upload_file(String.t(), keyword()) ::
          {:ok, String.t(), (-> :ok)} | {:error, term()}
  defp local_upload_file(file_path, context) do
    file_name = upload_file_name(file_path, context)

    if file_name == Path.basename(file_path) do
      {:ok, local_file_uri(file_path), fn -> :ok end}
    else
      with {:ok, alias_path, cleanup} <- create_local_upload_alias(file_path, file_name) do
        {:ok, local_file_uri(alias_path), cleanup}
      end
    end
  end

  @spec create_local_upload_alias(String.t(), String.t()) ::
          {:ok, String.t(), (-> :ok)} | {:error, term()}
  defp create_local_upload_alias(file_path, file_name) do
    upload_dir =
      file_path
      |> Path.dirname()
      |> Path.join(".telegram-upload-#{System.unique_integer([:positive])}")

    alias_path = Path.join(upload_dir, file_name)

    with :ok <- File.mkdir_p(upload_dir),
         :ok <- File.ln(file_path, alias_path) do
      {:ok, alias_path, fn -> cleanup_local_upload_alias(upload_dir, alias_path) end}
    else
      {:error, reason} ->
        File.rm_rf(upload_dir)
        {:error, {:local_upload_alias, reason}}
    end
  end

  @spec cleanup_local_upload_alias(String.t(), String.t()) :: :ok
  defp cleanup_local_upload_alias(upload_dir, alias_path) do
    File.rm(alias_path)
    File.rmdir(upload_dir)
    :ok
  end

  @spec upload_file_name(String.t(), keyword()) :: String.t()
  defp upload_file_name(file_path, context) do
    case Keyword.get(context, :post) do
      %Lolek.Post{title: title} when is_binary(title) and title != "" ->
        titled_file_name(file_path, title)

      _ ->
        Path.basename(file_path)
    end
  end

  @spec titled_file_name(String.t(), String.t()) :: String.t()
  defp titled_file_name(file_path, title) do
    extname = Path.extname(file_path)
    max_file_name_bytes = max_upload_file_name_bytes(file_path)

    title =
      title
      |> sanitize_upload_title()
      |> strip_trailing_extname(extname)
      |> truncate_file_stem(extname, max_file_name_bytes)
      |> String.trim()

    if title == "" do
      Path.basename(file_path)
    else
      title <> extname
    end
  end

  @spec max_upload_file_name_bytes(String.t()) :: pos_integer()
  defp max_upload_file_name_bytes(file_path) do
    # Respect the local alias filesystem while keeping names conservative for
    # clients that later save the Telegram file elsewhere.
    file_path
    |> Path.dirname()
    |> filesystem_name_max()
    |> min(@max_upload_file_name_bytes)
  end

  @spec filesystem_name_max(String.t()) :: pos_integer()
  defp filesystem_name_max(path) do
    case System.cmd("getconf", ["NAME_MAX", path], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {value, ""} when value > 0 -> value
          _ -> @max_upload_file_name_bytes
        end

      _ ->
        @max_upload_file_name_bytes
    end
  rescue
    ErlangError -> @max_upload_file_name_bytes
  end

  @spec strip_trailing_extname(String.t(), String.t()) :: String.t()
  defp strip_trailing_extname(title, ""), do: title

  defp strip_trailing_extname(title, extname) do
    if String.ends_with?(String.downcase(title), String.downcase(extname)) do
      String.slice(title, 0, String.length(title) - String.length(extname))
    else
      title
    end
  end

  @spec truncate_file_stem(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp truncate_file_stem(stem, extname, max_file_name_bytes) do
    stem
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, stem ->
      candidate_stem = stem <> grapheme

      if upload_file_name_byte_size(candidate_stem <> extname) > max_file_name_bytes do
        {:halt, stem}
      else
        {:cont, candidate_stem}
      end
    end)
  end

  @spec upload_file_name_byte_size(String.t()) :: non_neg_integer()
  defp upload_file_name_byte_size(file_name) do
    # Some client filesystems decompose Unicode before enforcing name limits.
    max(byte_size(file_name), byte_size(String.normalize(file_name, :nfd)))
  end

  @spec sanitize_upload_title(String.t()) :: String.t()
  defp sanitize_upload_title(title) do
    title
    |> String.replace(~r{https?://\S+}iu, "")
    |> String.replace(~r/[\x00-\x1F\x7F\/\\:*?"<>|]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec local_file_uri(String.t()) :: String.t()
  defp local_file_uri(file_path) do
    "file://" <> URI.encode(file_path, &file_uri_char?/1)
  end

  @spec file_uri_char?(non_neg_integer()) :: boolean()
  defp file_uri_char?(?/), do: true
  defp file_uri_char?(char), do: URI.char_unreserved?(char)

  @spec video_options(String.t()) :: keyword()
  defp video_options(file_path) do
    size =
      case Lolek.File.get_video_width_and_height(file_path) do
        {:ok, {width, height}} -> [width: width, height: height]
        _ -> []
      end

    case Lolek.File.get_video_duration(file_path) do
      {:ok, duration} -> size ++ [duration: duration]
      _ -> size
    end
  end

  @spec add_message_thread_id(keyword(), keyword()) :: keyword()
  defp add_message_thread_id(options, context) do
    case Keyword.get(context, :message_thread_id) do
      message_thread_id when is_integer(message_thread_id) ->
        Keyword.put(options, :message_thread_id, message_thread_id)

      _ ->
        options
    end
  end

  @spec requester_caption(keyword()) :: String.t() | nil
  defp requester_caption(context) do
    with true <- Application.fetch_env!(:lolek, :post_requester_caption),
         requester when is_binary(requester) <- Keyword.get(context, :requester_name),
         started_at when is_integer(started_at) <- Keyword.get(context, :started_at) do
      "#{requester} requested, processed in #{elapsed_seconds(started_at)}s"
    else
      _ -> nil
    end
  end

  @spec elapsed_seconds(integer()) :: String.t()
  defp elapsed_seconds(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000_000)
    |> then(&:io_lib.format("~.1f", [&1]))
    |> IO.iodata_to_binary()
  end

  @spec call_telegram((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  defp call_telegram(fun), do: call_telegram(fun, @flood_wait_attempts)

  @spec call_telegram((-> {:ok, term()} | {:error, term()}), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  defp call_telegram(fun, attempts_left) do
    if Lolek.ProcessingDeadline.expired?() do
      {:error, :processing_deadline_exceeded}
    else
      case run_telegram_call(fun) do
        {:error, {:telegram_api, error}} = failure ->
          retry_after_flood_wait(fun, error, attempts_left, failure)

        result ->
          result
      end
    end
  end

  @spec run_telegram_call((-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  defp run_telegram_call(fun) do
    case fun.() do
      {:error, %ExGram.Error{} = error} -> {:error, {:telegram_api, error}}
      result -> result
    end
  rescue
    error in ExGram.Error ->
      {:error, {:telegram_api, error}}
  end

  # The wait never outlives the processing deadline.
  @spec retry_after_flood_wait(
          (-> {:ok, term()} | {:error, term()}),
          ExGram.Error.t(),
          pos_integer(),
          {:error, term()}
        ) :: {:ok, term()} | {:error, term()}
  defp retry_after_flood_wait(fun, error, attempts_left, failure) do
    with true <- attempts_left > 1,
         {:ok, wait_ms} <- flood_wait_ms(error),
         true <- wait_ms <= remaining_deadline_ms() do
      Logger.warning("Telegram flood limit, waiting #{wait_ms}ms before a retry")
      Process.sleep(wait_ms)
      call_telegram(fun, attempts_left - 1)
    else
      _ -> failure
    end
  end

  @spec flood_wait_ms(ExGram.Error.t()) :: {:ok, pos_integer()} | :error
  defp flood_wait_ms(%ExGram.Error{code: 429, metadata: metadata}) do
    case retry_after_seconds(metadata) do
      seconds when is_integer(seconds) and seconds >= 0 ->
        {:ok, min((seconds + 1) * 1000, @max_flood_wait_ms)}

      _ ->
        :error
    end
  end

  defp flood_wait_ms(_error), do: :error

  @spec retry_after_seconds(term()) :: integer() | nil
  defp retry_after_seconds(%{parameters: parameters}) when is_list(parameters) do
    Enum.find_value(parameters, fn
      %{retry_after: seconds} when is_integer(seconds) -> seconds
      _ -> nil
    end)
  end

  defp retry_after_seconds(_metadata), do: nil

  @spec remaining_deadline_ms() :: non_neg_integer()
  defp remaining_deadline_ms do
    case Lolek.ProcessingDeadline.limit_timeout(:infinity) do
      :infinity -> @max_flood_wait_ms
      remaining when is_integer(remaining) -> remaining
    end
  end
end
