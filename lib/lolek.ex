defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024
  @max_caption_utf16_units 1024
  @caption_separator "\n\n"
  @caption_ellipsis "..."
  @max_upload_file_name_bytes 180
  @max_media_group_size 10
  @max_rich_media 50
  @flood_wait_attempts 2
  @max_flood_wait_ms 60_000
  @gif_extensions ~w(.gif)
  @photo_extensions ~w(.jpg .jpeg .png .webp .avif)

  @typep media_source :: {:file_path, String.t()} | {:file_id, String.t()}
  @typep media_item :: {media_source(), String.t()}
  @typep caption :: {String.t(), [ExGram.Model.MessageEntity.t()]}
  @typep requester_caption :: %{
           text: String.t(),
           name: String.t(),
           user: ExGram.Model.User.t() | nil
         }

  require Logger

  @spec send_file(integer(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, file_state), do: send_file(chat_id, file_state, [])

  @spec send_file(integer(), Lolek.File.file_state(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, {:prepared_media, cache_root, files}, context) do
    items = path_media_items(files)

    with {:ok, entries} <- send_media_collection(chat_id, items, context) do
      {:ok, {:sent_media, cache_root, entries}}
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
  defp send_media_collection(_chat_id, [], _context), do: {:error, :no_usable_media_files}

  # A rich message takes at most 50 media; a larger gallery would be rejected
  # and then uploaded twice.
  defp send_media_collection(chat_id, items, context) do
    kinded_items = Enum.map(items, fn {_source, ext} = item -> {rich_media_kind(ext), item} end)

    if length(items) <= @max_rich_media and Enum.all?(kinded_items, &elem(&1, 0)) do
      send_rich_post(chat_id, kinded_items, context)
    else
      send_classic_collection(chat_id, items, context)
    end
  end

  @spec send_classic_collection(integer(), [media_item()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_classic_collection(chat_id, [item], context) do
    send_single_media_item(chat_id, item, context)
  end

  defp send_classic_collection(chat_id, items, context) do
    send_media_group_items(chat_id, items, context)
  end

  @spec rich_media_kind(String.t()) :: Lolek.RichPost.media_kind() | nil
  defp rich_media_kind(ext) do
    cond do
      ext in @gif_extensions -> :animation
      video_ext?(ext) -> :video
      ext in @photo_extensions -> :photo
      true -> nil
    end
  end

  @spec video_ext?(String.t()) :: boolean()
  defp video_ext?(ext), do: Lolek.GalleryDownloader.video_file?("x#{ext}")

  @spec silent_if_video(boolean()) :: keyword()
  defp silent_if_video(true), do: [disable_notification: true]
  defp silent_if_video(false), do: []

  # A 400 means Telegram refused the post as a rich message, so the same media
  # go out the classic way. Any other failure (a flood limit, the deadline, a
  # dropped connection) may come after the post already landed, and resending
  # it would duplicate the post.
  @spec send_rich_post(
          integer(),
          [{Lolek.RichPost.media_kind(), media_item()}],
          keyword()
        ) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_rich_post(chat_id, kinded_items, context) do
    kinded_items = Lolek.RichPost.arrange(kinded_items)

    case send_rich_items(chat_id, kinded_items, context) do
      {:error, {:telegram_api, %ExGram.Error{code: 400} = error}} ->
        Logger.warning(
          "Telegram rejected the rich post, sending it the classic way. Reason: #{inspect(error)}"
        )

        send_classic_collection(chat_id, Enum.map(kinded_items, &elem(&1, 1)), context)

      result ->
        result
    end
  end

  @spec send_rich_items(
          integer(),
          [{Lolek.RichPost.media_kind(), media_item()}],
          keyword()
        ) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp send_rich_items(chat_id, kinded_items, context) do
    sources = Enum.map(kinded_items, fn {_kind, {source, _ext}} -> source end)

    result =
      with_media_sources(sources, context, fn prepared_sources ->
        media =
          kinded_items
          |> Enum.zip(prepared_sources)
          |> Enum.map(fn {{kind, {source, _ext}}, prepared_source} ->
            {kind, prepared_source, rich_media_attrs(kind, source)}
          end)

        rich_message =
          Lolek.RichPost.build(media,
            description: source_caption(context),
            mention: Lolek.PostOptions.requester_mention(context)
          )

        options = rich_post_options(kinded_items, context)
        call_telegram(fn -> Lolek.Telegram.send_rich_message(chat_id, rich_message, options) end)
      end)

    with {:ok, message} <- result do
      {:ok, rich_entries(kinded_items, message)}
    end
  end

  @spec rich_media_attrs(Lolek.RichPost.media_kind(), media_source()) :: keyword()
  defp rich_media_attrs(:video, {:file_path, file_path}),
    do: file_path |> get_options() |> Keyword.take([:width, :height, :duration])

  defp rich_media_attrs(_kind, _source), do: []

  @spec rich_post_options([{Lolek.RichPost.media_kind(), media_item()}], keyword()) :: keyword()
  defp rich_post_options(kinded_items, context) do
    kinded_items
    |> Enum.any?(&match?({:video, _item}, &1))
    |> silent_if_video()
    |> add_message_thread_id(context)
    |> Lolek.PostOptions.add_reply(context)
    |> Lolek.PostOptions.add_source_button(context)
  end

  # The post is already in the chat, so a response that cannot be matched to
  # the media only skips the cache instead of failing the request.
  @spec rich_entries([{Lolek.RichPost.media_kind(), media_item()}], term()) ::
          [{String.t(), String.t()}]
  defp rich_entries(kinded_items, message) do
    file_ids = Lolek.RichPost.file_ids(message)

    if length(file_ids) == length(kinded_items) do
      kinded_items
      |> Enum.zip(file_ids)
      |> Enum.map(fn {{_kind, {_source, ext}}, file_id} -> {ext, file_id} end)
    else
      Logger.warning(
        "Rich post was sent, but #{length(file_ids)} file ids came back for " <>
          "#{length(kinded_items)} media; the media will not be cached"
      )

      []
    end
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
    if video_ext?(ext) do
      file_path |> get_options() |> add_send_context(context)
    else
      add_send_context([], context)
    end
  end

  defp single_media_options({:file_id, _file_id}, ext, context) do
    ext |> video_ext?() |> silent_if_video() |> add_send_context(context)
  end

  @spec send_single_media(integer(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_single_media(chat_id, ext, source, options) when ext in @gif_extensions do
    call_telegram(fn -> Lolek.Telegram.send_animation(chat_id, source, options) end)
  end

  defp send_single_media(chat_id, ext, source, options) do
    cond do
      video_ext?(ext) ->
        call_telegram(fn -> Lolek.Telegram.send_video(chat_id, source, options) end)

      ext in @photo_extensions ->
        call_telegram(fn -> Lolek.Telegram.send_photo(chat_id, source, options) end)

      true ->
        call_telegram(fn -> Lolek.Telegram.send_document(chat_id, source, options) end)
    end
  end

  # Batches already in the chat cannot be taken back, so only a first batch
  # that never landed is an error.
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
          send_media_group_batch(chat_id, media, idx, context)
        end)

      case result do
        {:ok, messages} when is_list(messages) ->
          entries = extract_media_group_entries(batch, messages)
          {:cont, {:ok, acc_entries ++ entries}}

        {:ok, other} ->
          halt_media_group(
            acc_entries,
            {:error, {:unexpected_telegram_response, other}},
            idx,
            context
          )

        {:error, _} = error ->
          halt_media_group(acc_entries, error, idx, context)
      end
    end)
  end

  # The delete mode removes the request only after a complete post, so there a
  # partly sent album is a failure and the request stays.
  @spec halt_media_group(
          [{String.t(), String.t()}],
          {:error, term()},
          non_neg_integer(),
          keyword()
        ) :: {:halt, {:ok, [{String.t(), String.t()}]} | {:error, term()}}
  defp halt_media_group([], error, _idx, _context), do: {:halt, error}

  defp halt_media_group(acc_entries, {:error, reason} = error, idx, context) do
    if Keyword.get(context, :source_message_mode) == :delete do
      Logger.warning(
        "Media group batch #{idx} failed after #{length(acc_entries)} items were sent; " <>
          "keeping the request message. Reason: #{inspect(reason)}"
      )

      {:halt, error}
    else
      Logger.warning(
        "Media group batch #{idx} failed after #{length(acc_entries)} items were sent; " <>
          "keeping what reached the chat. Reason: #{inspect(reason)}"
      )

      {:halt, {:ok, acc_entries}}
    end
  end

  # Albums take no inline keyboard, so the source button is left out here.
  @spec send_media_group_batch(integer(), [term()], non_neg_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_media_group_batch(chat_id, media, batch_idx, context) do
    options = add_message_thread_id([], context)
    options = if batch_idx == 0, do: Lolek.PostOptions.add_reply(options, context), else: options
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

  @spec media_to_input_media(term(), String.t(), caption() | nil) :: term()
  defp media_to_input_media(source, ext, caption) do
    media =
      cond do
        ext in @gif_extensions ->
          %ExGram.Model.InputMediaDocument{type: "document", media: source}

        video_ext?(ext) ->
          %ExGram.Model.InputMediaVideo{type: "video", media: source}

        ext in @photo_extensions ->
          %ExGram.Model.InputMediaPhoto{type: "photo", media: source}

        true ->
          %ExGram.Model.InputMediaDocument{type: "document", media: source}
      end

    case caption do
      nil -> media
      {text, []} -> %{media | caption: text}
      {text, entities} -> %{media | caption: text, caption_entities: entities}
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
      nil ->
        options

      {text, []} ->
        Keyword.put(options, :caption, text)

      {text, entities} ->
        options |> Keyword.put(:caption, text) |> Keyword.put(:caption_entities, entities)
    end
  end

  @spec add_send_context(keyword(), keyword()) :: keyword()
  defp add_send_context(options, context) do
    options
    |> add_caption(context)
    |> add_message_thread_id(context)
    |> Lolek.PostOptions.add_reply(context)
    |> Lolek.PostOptions.add_source_button(context)
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

  @spec caption(keyword()) :: caption() | nil
  defp caption(context) do
    requester = requester_caption(context)
    requester_text = if requester, do: requester.text

    case build_caption(source_caption(context), requester_text) do
      nil -> nil
      text -> {text, caption_entities(text, requester)}
    end
  end

  # The mention is dropped when truncation cut into it: an entity must cover
  # exactly the text it marks.
  @spec caption_entities(String.t(), requester_caption() | nil) ::
          [ExGram.Model.MessageEntity.t()]
  defp caption_entities(text, %{
         text: requester_text,
         name: name,
         user: %ExGram.Model.User{} = user
       }) do
    if String.ends_with?(text, requester_text) do
      [
        %ExGram.Model.MessageEntity{
          type: "text_mention",
          offset: utf16_code_units(text) - utf16_code_units(name),
          length: utf16_code_units(name),
          user: user
        }
      ]
    else
      []
    end
  end

  defp caption_entities(_text, _requester), do: []

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

  @spec requester_caption(keyword()) :: requester_caption() | nil
  defp requester_caption(context) do
    case Lolek.PostOptions.requester_mention(context) do
      nil ->
        nil

      %ExGram.Model.RichTextTextMention{text: name, user: user} ->
        %{text: "requested by " <> name, name: name, user: user}

      name ->
        %{text: "requested by " <> name, name: name, user: nil}
    end
  end

  @spec build_caption(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp build_caption(nil, nil), do: nil

  defp build_caption(source_caption, nil),
    do: truncate_caption(source_caption, @max_caption_utf16_units)

  defp build_caption(nil, requester_caption),
    do: truncate_caption(requester_caption, @max_caption_utf16_units)

  defp build_caption(source_caption, requester_caption) do
    requester_caption = truncate_caption(requester_caption, @max_caption_utf16_units)

    available_source_utf16_units =
      @max_caption_utf16_units -
        utf16_code_units(requester_caption) - utf16_code_units(@caption_separator)

    if available_source_utf16_units > 0 do
      [
        truncate_caption(source_caption, available_source_utf16_units),
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

  defp truncate_caption(caption, max_utf16_units) do
    if utf16_code_units(caption) <= max_utf16_units do
      caption
    else
      ellipsis = take_utf16_prefix(@caption_ellipsis, max_utf16_units)
      caption_utf16_units = max_utf16_units - utf16_code_units(ellipsis)

      take_utf16_prefix(caption, caption_utf16_units) <> ellipsis
    end
  end

  @spec take_utf16_prefix(String.t(), non_neg_integer()) :: String.t()
  defp take_utf16_prefix(text, max_utf16_units) do
    {graphemes, _utf16_units} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {graphemes, utf16_units} ->
        candidate_utf16_units = utf16_units + utf16_code_units(grapheme)

        if candidate_utf16_units > max_utf16_units do
          {:halt, {graphemes, utf16_units}}
        else
          {:cont, {[grapheme | graphemes], candidate_utf16_units}}
        end
      end)

    graphemes
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec utf16_code_units(String.t()) :: non_neg_integer()
  defp utf16_code_units(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
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
