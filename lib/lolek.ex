defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024
  @max_caption_length 1024
  @caption_separator "\n\n"
  @max_upload_file_name_length 180

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
      ".mp4" ->
        options = get_options(file_path) |> add_caption(context)

        with {:ok, %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} = response} <-
               with_upload_file(file_path, context, fn upload ->
                 call_telegram(fn ->
                   Lolek.Telegram.send_video(chat_id, upload, options)
                 end)
               end) do
          update_caption_after_send(chat_id, response, context)
          {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
        else
          {:ok, response} -> {:error, {:unexpected_telegram_response, response}}
          {:error, _reason} = error -> error
        end

      _ ->
        options = add_caption([], context)

        with {:ok,
              %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} = response} <-
               with_upload_file(file_path, context, fn upload ->
                 call_telegram(fn ->
                   Lolek.Telegram.send_document(chat_id, upload, options)
                 end)
               end) do
          update_caption_after_send(chat_id, response, context)
          {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
        else
          {:ok, response} -> {:error, {:unexpected_telegram_response, response}}
          {:error, _reason} = error -> error
        end
    end
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
    if Application.get_env(:lolek, :telegram_local_file_uploads, false) do
      local_upload_file(file_path, context)
    else
      {:ok,
       {:file_content, File.stream!(file_path, [], @upload_chunk_size),
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
    if Application.get_env(:lolek, :post_source_caption, false) do
      case Keyword.get(context, :source_caption) do
        source_caption when is_binary(source_caption) and source_caption != "" -> source_caption
        _ -> nil
      end
    else
      nil
    end
  end

  @spec requester_caption(keyword()) :: String.t() | nil
  defp requester_caption(context) do
    with requester when is_binary(requester) <- Keyword.get(context, :requester_name),
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
