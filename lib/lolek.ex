defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024
  @max_caption_length 1024
  @caption_separator "\n\n"
  @max_upload_file_name_bytes 180
  @max_media_group_size 10
  @gif_extensions ~w(.gif)
  @photo_extensions ~w(.jpg .jpeg .png .webp .avif)

  @typep media_source :: {:file_path, String.t()} | {:file_id, String.t()}
  @typep media_item :: {media_source(), String.t()}

  require Logger

  @spec send_file(integer(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, file_state), do: send_file(chat_id, file_state, [])

  @spec send_file(integer(), Lolek.File.file_state(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, {:ready_to_telegram, file_path}, context) do
    extname = Path.extname(file_path) |> String.downcase()
    file_id = Path.basename(file_path, extname)

    with {:ok, response} <- send_ready_file(chat_id, file_id, extname, context) do
      update_caption_after_send(chat_id, response, context)
      {:ok, {:ready_to_telegram, file_path}}
    end
  end

  def send_file(chat_id, {:compressed, file_path}, context) do
    case Path.extname(file_path) |> String.downcase() do
      ".mp4" -> send_video_file(chat_id, file_path, context)
      _ -> send_document_file(chat_id, file_path, context)
    end
  end

  def send_file(chat_id, {:prepared_media, cache_root, files}, context) do
    items = path_media_items(files)

    with {:ok, entries} <- send_media_collection(chat_id, items, context) do
      {:ok, {:sent_media, cache_root, entries}}
    end
  end

  def send_file(chat_id, {:downloaded_gallery, gallery_dir, files}, context) do
    items = path_media_items(files)

    with {:ok, entries} <- send_media_collection(chat_id, items, context) do
      {:ok, {:sent_media, Path.dirname(gallery_dir), entries}}
    end
  end

  def send_file(chat_id, {:ready_media, entries}, context) do
    limited_entries = Enum.take(entries, max_gallery_media())
    items = Enum.map(limited_entries, fn {file_id, ext} -> {{:file_id, file_id}, ext} end)

    with {:ok, _sent_entries} <- send_media_collection(chat_id, items, context) do
      {:ok, {:ready_media, limited_entries}}
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

  @spec send_media_collection(integer(), [media_item()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_media_collection(_chat_id, [], _context), do: {:error, :no_usable_gallery_files}

  defp send_media_collection(chat_id, [item], context) do
    send_single_media_item(chat_id, item, context)
  end

  defp send_media_collection(chat_id, items, context) do
    send_media_group_items(chat_id, items, context)
  end

  @spec send_single_media_item(integer(), media_item(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_single_media_item(chat_id, {source, ext}, context) do
    options = single_media_options(source, ext, context)

    case with_media_sources([source], context, fn [prepared_source] ->
           send_single_media(chat_id, ext, prepared_source, options)
         end) do
      {:ok, response} ->
        case extract_single_file_id(response) do
          {:ok, file_id} ->
            update_caption_after_send(chat_id, response, context)
            {:ok, [{ext, file_id}]}

          :error ->
            {:error, {:unexpected_telegram_response, response}}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec single_media_options(media_source(), String.t(), keyword()) :: keyword()
  defp single_media_options({:file_path, file_path}, ext, context) do
    if Lolek.GalleryDownloader.video_file?("x#{ext}") do
      file_path |> get_options() |> add_send_context(context)
    else
      add_send_context([], context)
    end
  end

  defp single_media_options({:file_id, _file_id}, ext, context) do
    options =
      if Lolek.GalleryDownloader.video_file?("x#{ext}"),
        do: [disable_notification: true],
        else: []

    add_send_context(options, context)
  end

  @spec send_single_media(integer(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_single_media(chat_id, ext, source, options) when ext in @gif_extensions do
    call_telegram(fn -> Lolek.Telegram.send_animation(chat_id, source, options) end)
  end

  defp send_single_media(chat_id, ext, source, options) do
    cond do
      Lolek.GalleryDownloader.video_file?("x#{ext}") ->
        call_telegram(fn -> Lolek.Telegram.send_video(chat_id, source, options) end)

      ext in @photo_extensions ->
        call_telegram(fn -> Lolek.Telegram.send_photo(chat_id, source, options) end)

      true ->
        call_telegram(fn -> Lolek.Telegram.send_document(chat_id, source, options) end)
    end
  end

  @spec send_media_group_items(integer(), [media_item()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_media_group_items(chat_id, items, context) do
    items
    |> gallery_batches()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {batch, idx}, {:ok, acc_entries} ->
      result =
        with_media_sources(Enum.map(batch, &elem(&1, 0)), context, fn sources ->
          media = build_media_group(batch, sources, idx, context)
          send_media_group_batch(chat_id, media, context)
        end)

      case result do
        {:ok, messages} when is_list(messages) ->
          entries = extract_media_group_entries(batch, messages)
          {:cont, {:ok, acc_entries ++ entries}}

        {:ok, other} ->
          {:halt, {:error, {:unexpected_telegram_response, other}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  @spec send_media_group_batch(integer(), [term()], keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_media_group_batch(chat_id, media, context) do
    options = add_message_thread_id([], context)
    call_telegram(fn -> Lolek.Telegram.send_media_group(chat_id, media, options) end)
  end

  @spec gallery_batches([term()]) :: [[term()]]
  defp gallery_batches(items) do
    batches = Enum.chunk_every(items, @max_media_group_size)

    case Enum.reverse(batches) do
      [[single], previous | preceding] ->
        {moved, shortened_previous} = List.pop_at(previous, -1)
        Enum.reverse(preceding) ++ [shortened_previous, [moved, single]]

      _ ->
        batches
    end
  end

  @spec max_gallery_media() :: pos_integer()
  defp max_gallery_media do
    Application.fetch_env!(:lolek, :max_gallery_media)
  end

  @spec media_to_input_media(term(), String.t(), String.t() | nil) :: term()
  defp media_to_input_media(source, ext, caption) do
    cond do
      ext in @gif_extensions ->
        %ExGram.Model.InputMediaDocument{type: "document", media: source, caption: caption}

      Lolek.GalleryDownloader.video_file?("x#{ext}") ->
        %ExGram.Model.InputMediaVideo{type: "video", media: source, caption: caption}

      ext in @photo_extensions ->
        %ExGram.Model.InputMediaPhoto{type: "photo", media: source, caption: caption}

      true ->
        %ExGram.Model.InputMediaDocument{type: "document", media: source, caption: caption}
    end
  end

  @spec build_media_group([media_item()], [term()], non_neg_integer(), keyword()) :: [term()]
  defp build_media_group(batch, sources, batch_idx, context) do
    batch
    |> Enum.zip(sources)
    |> Enum.with_index()
    |> Enum.map(fn {{{_source, ext}, prepared_source}, file_idx} ->
      cap = if batch_idx == 0 and file_idx == 0, do: caption(context), else: nil
      media_to_input_media(prepared_source, ext, cap)
    end)
  end

  @spec extract_single_file_id(term()) :: {:ok, String.t()} | :error
  defp extract_single_file_id(%ExGram.Model.Message{photo: [_ | _] = sizes}) do
    {:ok, List.last(sizes).file_id}
  end

  defp extract_single_file_id(%ExGram.Model.Message{
         animation: %ExGram.Model.Animation{file_id: fid}
       }) do
    {:ok, fid}
  end

  defp extract_single_file_id(%ExGram.Model.Message{video: %ExGram.Model.Video{file_id: fid}}) do
    {:ok, fid}
  end

  defp extract_single_file_id(%ExGram.Model.Message{
         document: %ExGram.Model.Document{file_id: fid}
       }) do
    {:ok, fid}
  end

  defp extract_single_file_id(_), do: :error

  @spec extract_media_group_entries([media_item()], [term()]) :: [{String.t(), String.t()}]
  defp extract_media_group_entries(items, messages) do
    items
    |> Enum.zip(messages)
    |> Enum.flat_map(fn {{_source, ext}, message} ->
      case extract_single_file_id(message) do
        {:ok, fid} -> [{ext, fid}]
        :error -> []
      end
    end)
  end

  @spec send_video_file(integer(), String.t(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_video_file(chat_id, file_path, context) do
    options = get_options(file_path) |> add_send_context(context)

    case with_upload_file(file_path, context, fn upload ->
           do_send_video(chat_id, upload, options)
         end) do
      {:ok, %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} = response} ->
        update_caption_after_send(chat_id, response, context)
        ext = file_path |> Path.extname() |> String.downcase()
        {:ok, {:sent_media, Path.dirname(file_path), [{ext, file_id}]}}

      {:ok, response} ->
        {:error, {:unexpected_telegram_response, response}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec do_send_video(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp do_send_video(chat_id, upload, options) do
    call_telegram(fn -> Lolek.Telegram.send_video(chat_id, upload, options) end)
  end

  @spec send_document_file(integer(), String.t(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_document_file(chat_id, file_path, context) do
    options = add_send_context([], context)

    case with_upload_file(file_path, context, fn upload ->
           do_send_document(chat_id, upload, options)
         end) do
      {:ok, %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} = response} ->
        update_caption_after_send(chat_id, response, context)
        ext = file_path |> Path.extname() |> String.downcase()
        {:ok, {:sent_media, Path.dirname(file_path), [{ext, file_id}]}}

      {:ok, response} ->
        {:error, {:unexpected_telegram_response, response}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec do_send_document(integer(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp do_send_document(chat_id, upload, options) do
    call_telegram(fn -> Lolek.Telegram.send_document(chat_id, upload, options) end)
  end

  @spec with_upload_file(String.t(), keyword(), (term() -> term())) :: term()
  defp with_upload_file(file_path, context, fun) do
    with {:ok, upload, cleanup} <- upload_file(file_path, context) do
      try do
        fun.(upload)
      after
        cleanup.()
      end
    end
  end

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
    case Keyword.get(context, :source_title) do
      title when is_binary(title) and title != "" ->
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

  @spec send_ready_file(integer(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_ready_file(chat_id, file_id, ".mp4", context) do
    options = [disable_notification: true] |> add_send_context(context)

    call_telegram(fn ->
      Lolek.Telegram.send_video(chat_id, file_id, options)
    end)
  end

  defp send_ready_file(chat_id, file_id, _extname, context) do
    options = add_send_context([], context)

    call_telegram(fn -> Lolek.Telegram.send_document(chat_id, file_id, options) end)
  end

  @spec get_options(String.t()) :: Keyword.t()
  defp get_options(file_path) do
    options = [supports_streaming: true, disable_notification: true]

    options =
      case Lolek.File.get_video_width_and_height(file_path) do
        {:ok, {width, height}} ->
          options ++ [width: width, height: height]

        _ ->
          options
      end

    case Lolek.File.get_video_duration(file_path) do
      {:ok, duration} ->
        options ++ [duration: duration]

      _ ->
        options
    end
  end

  @spec add_caption(keyword(), keyword()) :: keyword()
  defp add_caption(options, context) do
    case caption(context) do
      nil -> options
      caption -> Keyword.put(options, :caption, caption)
    end
  end

  @spec add_send_context(keyword(), keyword()) :: keyword()
  defp add_send_context(options, context) do
    options
    |> add_caption(context)
    |> add_message_thread_id(context)
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

  @spec update_caption_after_send(integer(), term(), keyword()) :: :ok
  defp update_caption_after_send(chat_id, %ExGram.Model.Message{message_id: message_id}, context)
       when is_integer(message_id) and message_id > 0 do
    with caption when is_binary(caption) <- caption(context),
         {:error, reason} <-
           call_telegram(fn ->
             Lolek.Telegram.edit_message_caption(chat_id, message_id, caption: caption)
           end) do
      Logger.warning("Could not update Telegram message caption; reason: #{inspect(reason)}")
    end

    :ok
  end

  defp update_caption_after_send(_chat_id, _message, _context), do: :ok

  @spec caption(keyword()) :: String.t() | nil
  defp caption(context) do
    source_caption = source_caption(context)
    requester_caption = requester_caption(context)

    build_caption(source_caption, requester_caption)
  end

  @spec source_caption(keyword()) :: String.t() | nil
  defp source_caption(context) do
    with true <- Application.fetch_env!(:lolek, :post_source_caption),
         source_caption when is_binary(source_caption) and source_caption != "" <-
           Keyword.get(context, :source_caption) do
      source_caption
    else
      _ -> nil
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

  @spec build_caption(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp build_caption(nil, nil), do: nil

  defp build_caption(source_caption, nil),
    do: truncate_caption(source_caption, @max_caption_length)

  defp build_caption(nil, requester_caption),
    do: truncate_caption(requester_caption, @max_caption_length)

  defp build_caption(source_caption, requester_caption) do
    requester_caption = truncate_caption(requester_caption, @max_caption_length)

    available_source_length =
      @max_caption_length - String.length(requester_caption) - String.length(@caption_separator)

    if available_source_length > 0 do
      [
        truncate_caption(source_caption, available_source_length),
        requester_caption
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(@caption_separator)
    else
      requester_caption
    end
  end

  @spec truncate_caption(String.t(), non_neg_integer()) :: String.t()
  defp truncate_caption(_caption, 0), do: ""

  defp truncate_caption(caption, max_length) do
    if String.length(caption) <= max_length do
      caption
    else
      caption
      |> String.slice(0, max(max_length - 3, 0))
      |> Kernel.<>("...")
      |> String.slice(0, max_length)
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
  defp call_telegram(fun) do
    if Lolek.ProcessingDeadline.expired?() do
      {:error, :processing_deadline_exceeded}
    else
      case fun.() do
        {:error, %ExGram.Error{} = error} -> {:error, {:telegram_api, error}}
        result -> result
      end
    end
  rescue
    error in ExGram.Error ->
      {:error, {:telegram_api, error}}
  end
end
