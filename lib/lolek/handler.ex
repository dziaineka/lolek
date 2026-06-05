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
        case Lolek.UrlProcessing.process(url, fn ->
               Lolek.ProcessingLimiter.with_limit(chat_id, fn ->
                 process_url(chat_id, url, Lolek.Requester.display_name(from))
               end)
             end) do
          {:ok, _file_state} ->
            :ok

          {:error, :no_video_formats} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Error when processing url: #{Lolek.Url.normalize_for_log(url)}; reason: #{inspect(reason)}"
            )

            :ok
        end

      {:error, :no_url} ->
        :ok

      {:error, reason} ->
        Logger.warning("Error when processing message; reason: #{inspect(reason)}")
        :ok
    end
  end

  def handle(_, _context) do
    :ok
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
         source_caption <- source_caption(url, folder_path, log_url),
         send_context = [
           requester_name: requester_name,
           started_at: started_at,
           source_caption: source_caption
         ],
         {:ok, file_state} <-
           timed_step("cache lookup", log_url, fn -> Lolek.File.get_file_state(folder_path) end),
         {:ok, file_state} <-
           timed_step("download", log_url, fn -> Lolek.Downloader.download(url, file_state) end),
         {:ok, file_state} <-
           timed_step("conversion", log_url, fn ->
             Lolek.Converter.adapt_to_telegram(file_state)
           end),
         {:ok, file_state} <-
           timed_step("telegram send", log_url, fn ->
             Lolek.send_file(chat_id, file_state, send_context)
           end) do
      case timed_step("cache update", log_url, fn ->
             Lolek.File.move_to_ready_to_telegram(file_state)
           end) do
        :ok -> {:ok, file_state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec source_caption(String.t(), String.t(), String.t()) :: String.t() | nil
  defp source_caption(url, folder_path, log_url) do
    case timed_step("metadata", log_url, fn ->
           Lolek.SourceMetadata.get_or_fetch(url, folder_path)
         end) do
      {:ok, caption} ->
        caption

      {:error, reason} ->
        Logger.warning(
          "Error when fetching source metadata for url: #{log_url}; reason: #{inspect(reason)}"
        )

        nil
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

    Logger.info(
      "Finished #{name} for url: #{log_url}; elapsed_ms=#{format_elapsed_ms(elapsed_ms)}; result=#{format_step_result(result)}"
    )

    result
  end

  @spec format_elapsed_ms(float()) :: String.t()
  defp format_elapsed_ms(elapsed_ms) do
    :io_lib.format("~.1f", [elapsed_ms]) |> IO.iodata_to_binary()
  end

  @spec format_step_result(term()) :: String.t()
  defp format_step_result({:ok, nil}), do: "ok:no_source_caption"
  defp format_step_result({:ok, caption}) when is_binary(caption), do: "ok:source_caption"
  defp format_step_result({:ok, file_state}), do: "ok:#{format_file_state(file_state)}"
  defp format_step_result(:ok), do: "ok"
  defp format_step_result({:error, reason}), do: "error:#{inspect(reason)}"
  defp format_step_result(other), do: inspect(other)

  @spec format_file_state(term()) :: String.t()
  defp format_file_state({:ready_to_telegram, _file_path}), do: "ready_to_telegram"
  defp format_file_state({:compressed, _file_path}), do: "compressed"
  defp format_file_state({:downloaded, _file_path}), do: "downloaded"
  defp format_file_state({:new_file, _folder_path}), do: "new_file"

  defp format_file_state({:sent_to_telegram_at_first, _file_path, _file_id}),
    do: "sent_to_telegram_at_first"

  defp format_file_state(other), do: inspect(other)
end
