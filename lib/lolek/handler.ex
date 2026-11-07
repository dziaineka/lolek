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
  def handle({:command, :start, %ExGram.Model.Message{} = message}, context) do
    with_fresh_message(message, fn ->
      answer(context, "Hi! Send me an url and I will try to show media from it.")
    end)
  end

  def handle(
        {
          :text,
          text,
          %ExGram.Model.Message{
            chat: %ExGram.Model.Chat{id: chat_id},
            from: from
          } = message
        },
        _context
      ) do
    with_fresh_message(message, fn ->
      result =
        with_processing_deadline(message, fn ->
          handle_text_message(text, chat_id, from, topic_message_thread_id(message))
        end)

      maybe_react_to_failure(message, result)
    end)
  end

  def handle(_, _context) do
    :ok
  end

  @doc false
  @spec topic_message_thread_id(ExGram.Model.Message.t()) :: integer() | nil
  def topic_message_thread_id(%ExGram.Model.Message{
        is_topic_message: true,
        message_thread_id: message_thread_id
      })
      when is_integer(message_thread_id),
      do: message_thread_id

  def topic_message_thread_id(%ExGram.Model.Message{}), do: nil

  @spec handle_text_message(String.t(), integer(), ExGram.Model.User.t() | nil, integer() | nil) ::
          :ok | {:failure, term()}
  defp handle_text_message(text, chat_id, from, message_thread_id) do
    case Lolek.Url.extract_url(text) do
      {:ok, url} ->
        case process_admitted_url(chat_id, url, from, message_thread_id) do
          {:ok, _file_state} ->
            Lolek.Metrics.record_message_result(:ok)
            :ok

          {:error, :no_video_formats} ->
            Lolek.Metrics.record_message_result(:no_video_formats)
            :ok

          {:error, :chat_rate_limited} ->
            Lolek.Metrics.record_message_result(:chat_rate_limited)
            Logger.warning("Dropping url from chat #{chat_id}: chat rate limit exceeded")
            {:failure, :chat_rate_limited}

          {:error, reason} ->
            Lolek.Metrics.record_message_result({:error, reason})

            Logger.warning(
              "Error when processing url: #{Lolek.Url.normalize_for_log(url)}; reason: #{inspect(reason)}"
            )

            {:failure, reason}
        end

      {:error, :no_url} ->
        Lolek.Metrics.record_message_result(:no_url)
        :ok
    end
  end

  @spec maybe_react_to_failure(ExGram.Model.Message.t(), :ok | {:failure, term()}) :: :ok
  defp maybe_react_to_failure(
         %ExGram.Model.Message{
           chat: %ExGram.Model.Chat{id: chat_id},
           message_id: message_id
         },
         {:failure, reason}
       ) do
    Lolek.FailureReaction.react(chat_id, message_id, reason)
  end

  defp maybe_react_to_failure(%ExGram.Model.Message{}, :ok), do: :ok

  @spec process_admitted_url(
          integer(),
          String.t(),
          ExGram.Model.User.t() | nil,
          integer() | nil
        ) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_admitted_url(chat_id, url, from, message_thread_id) do
    if Lolek.ChatRateLimiter.admit?(chat_id) do
      Lolek.UrlProcessing.process(url, fn ->
        process_url_with_limit(chat_id, url, from, message_thread_id)
      end)
    else
      {:error, :chat_rate_limited}
    end
  end

  @spec process_url_with_limit(
          integer(),
          String.t(),
          ExGram.Model.User.t() | nil,
          integer() | nil
        ) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_url_with_limit(chat_id, url, from, message_thread_id) do
    Lolek.ProcessingLimiter.with_limit(chat_id, fn ->
      process_url(chat_id, url, Lolek.Requester.display_name(from), message_thread_id)
    end)
  end

  @spec with_fresh_message(ExGram.Model.Message.t(), (-> term())) :: term()
  defp with_fresh_message(message, fun) when is_function(fun, 0) do
    max_delay_seconds = Application.fetch_env!(:lolek, :max_message_delay_seconds)

    delay_seconds = message_delay_seconds(message)

    if delay_seconds >= max_delay_seconds do
      Lolek.Metrics.record_message_result(:stale_message)

      Logger.warning(
        "Dropping stale Telegram message from chat #{inspect(message_chat_id(message))}; " <>
          "delay_seconds=#{delay_seconds}; max_delay_seconds=#{max_delay_seconds}"
      )

      :ok
    else
      fun.()
    end
  end

  @spec message_delay_seconds(ExGram.Model.Message.t()) :: integer()
  defp message_delay_seconds(%ExGram.Model.Message{date: date}) do
    System.system_time(:second) - date
  end

  @spec message_chat_id(ExGram.Model.Message.t()) :: integer()
  defp message_chat_id(%ExGram.Model.Message{chat: %ExGram.Model.Chat{id: chat_id}}), do: chat_id

  @spec with_processing_deadline(ExGram.Model.Message.t(), (-> term())) :: term()
  defp with_processing_deadline(message, fun) when is_function(fun, 0) do
    max_delay_seconds = Application.fetch_env!(:lolek, :max_message_delay_seconds)
    timeout = remaining_message_time(message, max_delay_seconds)

    case Lolek.ProcessingDeadline.run(fun, timeout) do
      {:error, :processing_deadline_exceeded} ->
        Lolek.Metrics.record_message_result(:processing_deadline_exceeded)

        Logger.warning(
          "Stopping Telegram message processing for chat #{inspect(message_chat_id(message))}: " <>
            "overall deadline exceeded; max_delay_seconds=#{max_delay_seconds}"
        )

        {:failure, :processing_deadline_exceeded}

      result ->
        result
    end
  end

  @spec remaining_message_time(ExGram.Model.Message.t(), pos_integer()) :: non_neg_integer()
  defp remaining_message_time(%ExGram.Model.Message{date: date}, max_delay_seconds) do
    deadline = :timer.seconds(date + max_delay_seconds)
    max(deadline - System.system_time(:millisecond), 0)
  end

  @spec process_url(integer(), String.t(), String.t(), integer() | nil) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp process_url(chat_id, url, requester_name, message_thread_id) do
    log_url = Lolek.Url.normalize_for_log(url)
    started_at = System.monotonic_time()

    timed_step("total", log_url, fn ->
      do_process_url(chat_id, url, log_url, requester_name, message_thread_id, started_at)
    end)
  end

  @spec do_process_url(
          integer(),
          String.t(),
          String.t(),
          String.t(),
          integer() | nil,
          integer()
        ) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  defp do_process_url(chat_id, url, log_url, requester_name, message_thread_id, started_at) do
    with {:ok, folder_path} <- Lolek.File.get_folder_path(url),
         post <- source_post(url, folder_path, log_url),
         send_context = [
           requester_name: requester_name,
           message_thread_id: message_thread_id,
           started_at: started_at,
           post: post
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

  # gallery-dl writes the post metadata next to the downloaded files.
  @spec enrich_gallery_context(keyword(), Lolek.File.file_state()) :: keyword()
  defp enrich_gallery_context(context, {state, cache_root, _files_or_text})
       when state in [:downloaded_media, :text_post] do
    gallery_dir = Path.join(cache_root, "gallery")
    post = Keyword.get(context, :post) || Lolek.Post.empty()

    Keyword.put(
      context,
      :post,
      Lolek.SourceMetadata.merge_gallery_metadata(post, cache_root, gallery_dir)
    )
  end

  defp enrich_gallery_context(context, _file_state), do: context

  @spec source_post(String.t(), String.t(), String.t()) :: Lolek.Post.t()
  defp source_post(url, folder_path, log_url) do
    case timed_step("metadata", log_url, fn ->
           Lolek.SourceMetadata.get_or_fetch(url, folder_path)
         end) do
      {:ok, post} ->
        post

      {:error, reason} ->
        Logger.warning(
          "Error when fetching source metadata for url: #{log_url}; reason: #{inspect(reason)}"
        )

        Lolek.Post.empty(url)
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
  defp format_step_result({:ok, %Lolek.Post{} = post}) do
    "ok:post:platform=#{post.platform}:author=#{not is_nil(post.author)}:" <>
      "text=#{present?(post.text)}:quoted=#{not is_nil(post.quoted)}"
  end

  defp format_step_result({:ok, file_state}), do: "ok:#{format_file_state(file_state)}"
  defp format_step_result(:ok), do: "ok"
  defp format_step_result({:error, reason}), do: "error:#{inspect(reason)}"

  @spec present?(term()) :: boolean()
  defp present?(value), do: is_binary(value) and value != ""

  @spec format_file_state(term()) :: String.t()
  defp format_file_state({:ready_media, entries}),
    do: "ready_media:count=#{length(entries)}"

  defp format_file_state({:downloaded_media, _cache_root, files}),
    do: "downloaded_media:count=#{length(files)}"

  defp format_file_state({:prepared_media, _cache_root, files}),
    do: "prepared_media:count=#{length(files)}"

  defp format_file_state({:new_file, _folder_path}), do: "new_file"

  defp format_file_state({:sent_media, _cache_root, entries}),
    do: "sent_media:count=#{length(entries)}"

  defp format_file_state({:text_post, _cache_root, text}),
    do: "text_post:length=#{String.length(text)}"

  defp format_file_state(other), do: inspect(other)
end
