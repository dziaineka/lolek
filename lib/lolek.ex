defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024
  @max_caption_length 1024
  @caption_separator "\n\n"
  @max_upload_file_name_length 180
  @max_media_group_size 10
  @gif_extensions ~w(.gif)

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

  def send_file(chat_id, {:downloaded_gallery, gallery_dir, [file_path]}, context) do
    send_single_gallery_file(chat_id, gallery_dir, file_path, context)
  end

  def send_file(chat_id, {:downloaded_gallery, gallery_dir, files}, context) do
    send_gallery_files(chat_id, gallery_dir, files, context)
  end

  def send_file(chat_id, {:ready_to_telegram_gallery, entries}, context) do
    send_cached_gallery(chat_id, entries, context)
  end

  @spec send_single_gallery_file(integer(), String.t(), String.t(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_single_gallery_file(chat_id, gallery_dir, file_path, context) do
    options = add_caption([], context)
    ext = file_path |> Path.extname() |> String.downcase()

    upload =
      {:file_content, File.stream!(file_path, @upload_chunk_size, []), Path.basename(file_path)}

    case send_gallery_single_upload(chat_id, ext, upload, options) do
      {:ok, response} ->
        case extract_single_file_id(response) do
          {:ok, file_id} ->
            {:ok, {:sent_gallery_to_telegram_at_first, gallery_dir, [{ext, file_id}]}}

          :error ->
            {:error, {:unexpected_telegram_response, response}}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec send_gallery_single_upload(integer(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp send_gallery_single_upload(chat_id, ext, upload, options) when ext in @gif_extensions do
    call_telegram(fn -> Lolek.Telegram.send_animation(chat_id, upload, options) end)
  end

  defp send_gallery_single_upload(chat_id, _ext, upload, options) do
    call_telegram(fn -> Lolek.Telegram.send_photo(chat_id, upload, options) end)
  end

  @spec send_gallery_files(integer(), String.t(), [String.t()], keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_gallery_files(chat_id, gallery_dir, files, context) do
    files
    |> Enum.chunk_every(@max_media_group_size)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {batch, idx}, {:ok, acc_entries} ->
      cap = if idx == 0, do: caption(context), else: nil
      media = Enum.map(batch, &file_to_input_media(&1, cap))

      case send_media_group_batch(chat_id, media) do
        {:ok, messages} when is_list(messages) ->
          entries = extract_media_group_entries(batch, messages)
          {:cont, {:ok, acc_entries ++ entries}}

        {:ok, other} ->
          {:halt, {:error, {:unexpected_telegram_response, other}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, {:sent_gallery_to_telegram_at_first, gallery_dir, entries}}
      error -> error
    end
  end

  @spec send_media_group_batch(integer(), [term()]) :: {:ok, term()} | {:error, term()}
  defp send_media_group_batch(chat_id, media) do
    call_telegram(fn -> Lolek.Telegram.send_media_group(chat_id, media, []) end)
  end

  @spec send_cached_gallery(integer(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_cached_gallery(chat_id, entries, context) do
    entries
    |> Enum.chunk_every(@max_media_group_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      cap = if idx == 0, do: caption(context), else: nil

      media =
        Enum.map(batch, fn {file_id, ext} ->
          cached_file_to_input_media(file_id, ext, cap)
        end)

      call_telegram(fn -> Lolek.Telegram.send_media_group(chat_id, media, []) end)
    end)

    {:ok, {:ready_to_telegram_gallery, entries}}
  end

  @spec file_to_input_media(String.t(), String.t() | nil) :: term()
  defp file_to_input_media(file_path, caption) do
    ext = file_path |> Path.extname() |> String.downcase()

    upload =
      {:file_content, File.stream!(file_path, @upload_chunk_size, []), Path.basename(file_path)}

    if ext in @gif_extensions do
      %ExGram.Model.InputMediaDocument{type: "document", media: upload, caption: caption}
    else
      %ExGram.Model.InputMediaPhoto{type: "photo", media: upload, caption: caption}
    end
  end

  @spec cached_file_to_input_media(String.t(), String.t(), String.t() | nil) :: term()
  defp cached_file_to_input_media(file_id, ext, caption) do
    if ext in @gif_extensions do
      %ExGram.Model.InputMediaDocument{type: "document", media: file_id, caption: caption}
    else
      %ExGram.Model.InputMediaPhoto{type: "photo", media: file_id, caption: caption}
    end
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

  defp extract_single_file_id(_), do: :error

  @spec extract_media_group_entries([String.t()], [term()]) :: [{String.t(), String.t()}]
  defp extract_media_group_entries(file_paths, messages) do
    file_paths
    |> Enum.zip(messages)
    |> Enum.flat_map(fn {file_path, message} ->
      ext = file_path |> Path.extname() |> String.downcase()

      case extract_single_file_id(message) do
        {:ok, fid} -> [{ext, fid}]
        :error -> []
      end
    end)
  end

  @spec send_video_file(integer(), String.t(), keyword()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp send_video_file(chat_id, file_path, context) do
    options = get_options(file_path) |> add_caption(context)

    case with_upload_file(file_path, context, fn upload ->
           do_send_video(chat_id, upload, options)
         end) do
      {:ok, %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} = response} ->
        update_caption_after_send(chat_id, response, context)
        {:ok, {:sent_to_telegram_at_first, file_path, file_id}}

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
    options = add_caption([], context)

    case with_upload_file(file_path, context, fn upload ->
           do_send_document(chat_id, upload, options)
         end) do
      {:ok, %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} = response} ->
        update_caption_after_send(chat_id, response, context)
        {:ok, {:sent_to_telegram_at_first, file_path, file_id}}

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
    max_title_length = max(@max_upload_file_name_length - String.length(extname), 1)

    title =
      title
      |> sanitize_upload_title()
      |> String.slice(0, max_title_length)
      |> String.trim()

    cond do
      title == "" ->
        Path.basename(file_path)

      String.ends_with?(String.downcase(title), String.downcase(extname)) ->
        title

      true ->
        title <> extname
    end
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
    options = [disable_notification: true] |> add_caption(context)

    call_telegram(fn ->
      Lolek.Telegram.send_video(chat_id, file_id, options)
    end)
  end

  defp send_ready_file(chat_id, file_id, _extname, context) do
    options = add_caption([], context)

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
    case fun.() do
      {:error, %ExGram.Error{} = error} -> {:error, {:telegram_api, error}}
      result -> result
    end
  rescue
    error in ExGram.Error ->
      {:error, {:telegram_api, error}}
  end
end
