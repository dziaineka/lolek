defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """
  @upload_chunk_size 64 * 1024

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
               call_telegram(fn ->
                 Lolek.Telegram.send_video(chat_id, upload_file(file_path), options)
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
               call_telegram(fn ->
                 Lolek.Telegram.send_document(chat_id, upload_file(file_path), options)
               end) do
          update_caption_after_send(chat_id, response, context)
          {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
        else
          {:ok, response} -> {:error, {:unexpected_telegram_response, response}}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec upload_file(String.t()) :: {:file_content, File.Stream.t(), String.t()} | String.t()
  defp upload_file(file_path) do
    if Application.get_env(:lolek, :telegram_local_file_uploads, false) do
      local_file_uri(file_path)
    else
      {:file_content, File.stream!(file_path, [], @upload_chunk_size), Path.basename(file_path)}
    end
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
    with requester when is_binary(requester) <- Keyword.get(context, :requester_name),
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
