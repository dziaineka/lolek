defmodule Lolek.Handler do
  @moduledoc """
  This module is responsible for handling the bot's commands and messages.
  """
  @bot :lolek

  require Logger

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  command("start")
  command("help", description: "Print the bot's help")

  middleware(ExGram.Middleware.IgnoreUsername)

  # {:command, key, message} → This tuple will match when a command is received
  # {:text, text, message} → This tuple will match when plain text is sent to the bot (check privacy mode)
  # {:regex, key, message} → This tuple will match if a regex is defined at the beginning of the module
  # {:location, location} → This tuple will match when a location message is received
  # {:callback_query, callback_query} → This tuple will match when a Callback Query is received
  # {:inline_query, inline_query} → This tuple will match when an Inline Query is received
  # {:edited_message, edited_message} → This tuple will match when a message is edited
  # {:message, message} → This will match any message that does not fit with the ones described above
  # {:update, update} → This tuple will match as a default handle

  @impl true
  def handle({:command, :start, _msg}, context) do
    answer(context, "Hi! Send me an url and I will try to show media from it.")
  end

  def handle(
        {
          :text,
          text,
          %ExGram.Model.Message{chat: %ExGram.Model.Chat{id: chat_id}, from: from}
        },
        _context
      ) do
    case Lolek.Url.extract_url(text) do
      {:ok, url} ->
        case process_admitted_url(chat_id, url, from) do
          {:ok, _file_state} ->
            Lolek.Metrics.record_message_result(:ok)
            :ok

          {:error, :no_video_formats} ->
            Lolek.Metrics.record_message_result(:no_video_formats)
            :ok

          {:error, :chat_rate_limited} ->
            Lolek.Metrics.record_message_result(:chat_rate_limited)
            Logger.warning("Dropping url from chat #{chat_id}: chat rate limit exceeded")
            :ok

          {:error, reason} ->
            Lolek.Metrics.record_message_result({:error, reason})

            Logger.warning(
              "Error when processing url: #{Lolek.Url.normalize_for_log(url)}; reason: #{inspect(reason)}"
            )

            :ok
        end

      {:error, :no_url} ->
        Lolek.Metrics.record_message_result(:no_url)
        :ok
    end
  end

  def handle(_, _context) do
    :ok
  end

  @spec process_admitted_url(integer(), String.t(), ExGram.Model.User.t() | nil) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_admitted_url(chat_id, url, from) do
    if Lolek.ChatRateLimiter.admit?(chat_id) do
      Lolek.UrlProcessing.process(url, fn ->
        process_url_with_limit(chat_id, url, from)
      end)
    else
      {:error, :chat_rate_limited}
    end
  end

  @spec process_url_with_limit(integer(), String.t(), ExGram.Model.User.t() | nil) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_url_with_limit(chat_id, url, from) do
    Lolek.ProcessingLimiter.with_limit(chat_id, fn ->
      process_url(chat_id, url, Lolek.Requester.display_name(from))
    end)
  end

  @spec process_url(integer(), String.t(), String.t()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_url(chat_id, url, requester_name) do
    log_url = Lolek.Url.normalize_for_log(url)
    started_at = System.monotonic_time()

    timed_step("total", log_url, fn ->
      do_process_url(chat_id, url, log_url, requester_name, started_at)
    end)
  end

  @spec do_process_url(integer(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp do_process_url(chat_id, url, log_url, requester_name, started_at) do
    with {:ok, folder_path} <- Lolek.File.get_folder_path(url),
         source_metadata <- source_metadata(url, folder_path, log_url),
         send_context = [
           requester_name: requester_name,
           started_at: started_at,
           source_caption: source_metadata.caption,
           source_title: source_metadata.title
         ],
         {:ok, file_state} <-
           timed_step("cache lookup", log_url, fn -> Lolek.File.get_file_state(folder_path) end),
         {:ok, file_state} <-
           timed_step("download", log_url, fn -> Lolek.Downloader.download(url, file_state) end),
         send_context = enrich_gallery_context(send_context, file_state),
         {:ok, file_state} <-
           timed_step("conversion", log_url, fn ->
             Lolek.Converter.adapt_to_telegram(file_state)
           end),
         {:ok, file_state} <-
           timed_step("telegram send", log_url, fn ->
             Lolek.send_file(chat_id, file_state, send_context)
           end),
         :ok <-
           timed_step("cache update", log_url, fn ->
             Lolek.File.move_to_ready_to_telegram(file_state)
           end) do
      {:ok, file_state}
    end
  end

  @spec enrich_gallery_context(keyword(), Lolek.File.file_state()) :: keyword()
  defp enrich_gallery_context(context, {:downloaded_gallery, gallery_dir, _files}) do
    with nil <- Keyword.get(context, :source_caption),
         {:ok, caption} <- Lolek.GalleryDownloader.read_caption(gallery_dir) do
      folder_path = Path.dirname(gallery_dir)
      Lolek.SourceMetadata.cache_gallery_caption(folder_path, caption)
      Keyword.put(context, :source_caption, caption)
    else
      _ -> context
    end
  end

  defp enrich_gallery_context(context, _file_state), do: context

  @spec source_metadata(String.t(), String.t(), String.t()) :: Lolek.SourceMetadata.t()
  defp source_metadata(url, folder_path, log_url) do
    case timed_step("metadata", log_url, fn ->
           Lolek.SourceMetadata.get_or_fetch(url, folder_path)
         end) do
      {:ok, metadata} ->
        metadata

      {:error, reason} ->
        Logger.warning(
          "Error when fetching source metadata for url: #{log_url}; reason: #{inspect(reason)}"
        )

        Lolek.SourceMetadata.empty()
    end
  end

  @spec timed_step(String.t(), String.t(), (-> term())) :: term()
  defp timed_step(name, log_url, fun) do
    started_at = System.monotonic_time()
    result = fun.()

    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1000)

    Lolek.Metrics.record_processing_stage(name, result, elapsed_ms)
    record_step_metrics(name, result)

    Logger.info(
      "Finished #{name} for url: #{log_url}; elapsed_ms=#{format_elapsed_ms(elapsed_ms)}; result=#{format_step_result(result)}"
    )

    result
  end

  @spec record_step_metrics(String.t(), term()) :: :ok
  defp record_step_metrics("cache lookup", result), do: Lolek.Metrics.record_cache_lookup(result)
  defp record_step_metrics(_name, _result), do: :ok

  @spec format_elapsed_ms(float()) :: String.t()
  defp format_elapsed_ms(elapsed_ms) do
    :io_lib.format("~.1f", [elapsed_ms]) |> IO.iodata_to_binary()
  end

  @spec format_step_result(term()) :: String.t()
  defp format_step_result({:ok, %{caption: caption, title: title}}) do
    "ok:source_metadata:caption=#{present?(caption)}:title=#{present?(title)}"
  end

  defp format_step_result({:ok, file_state}), do: "ok:#{format_file_state(file_state)}"
  defp format_step_result(:ok), do: "ok"
  defp format_step_result({:error, reason}), do: "error:#{inspect(reason)}"

  @spec present?(term()) :: boolean()
  defp present?(value), do: is_binary(value) and value != ""

  @spec format_file_state(term()) :: String.t()
  defp format_file_state({:ready_to_telegram, _file_path}), do: "ready_to_telegram"

  defp format_file_state({:ready_to_telegram_gallery, entries}),
    do: "ready_to_telegram_gallery:count=#{length(entries)}"

  defp format_file_state({:compressed, _file_path}), do: "compressed"
  defp format_file_state({:downloaded, _file_path}), do: "downloaded"

  defp format_file_state({:downloaded_gallery, _gallery_dir, files}),
    do: "downloaded_gallery:count=#{length(files)}"

  defp format_file_state({:new_file, _folder_path}), do: "new_file"

  defp format_file_state({:sent_to_telegram_at_first, _file_path, _file_id}),
    do: "sent_to_telegram_at_first"

  defp format_file_state({:sent_gallery_to_telegram_at_first, _gallery_dir, entries}),
    do: "sent_gallery_to_telegram_at_first:count=#{length(entries)}"

  defp format_file_state(other), do: inspect(other)
end
