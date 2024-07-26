defmodule Lolek.Bot do
  @bot :lolek

  require Logger

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  command("start")
  command("help", description: "Print the bot's help")

  middleware(ExGram.Middleware.IgnoreUsername)

  def bot(), do: @bot

  # {:command, key, message} → This tuple will match when a command is received
  # {:text, text, message} → This tuple will match when plain text is sent to the bot (check privacy mode)
  # {:regex, key, message} → This tuple will match if a regex is defined at the beginning of the module
  # {:location, location} → This tuple will match when a location message is received
  # {:callback_query, callback_query} → This tuple will match when a Callback Query is received
  # {:inline_query, inline_query} → This tuple will match when an Inline Query is received
  # {:edited_message, edited_message} → This tuple will match when a message is edited
  # {:message, message} → This will match any message that does not fit with the ones described above
  # {:update, update} → This tuple will match as a default handle

  def handle({:command, :start, _msg}, context) do
    answer(context, "Hi! Send me an url and I will try to show media from it.")
  end

  def handle(
        {:text, text, %ExGram.Model.Message{chat: %ExGram.Model.Chat{id: chat_id}}},
        _context
      ) do
    with {:ok, url} <- Lolek.Url.extract_url(text),
         {:ok, folder_path} <- Lolek.File.get_folder_path(url),
         {:ok, file_state} <- Lolek.File.get_file_state(folder_path),
         {:ok, file_state} <- Lolek.Downloader.download(url, file_state),
         {:ok, file_state} <- Lolek.Converter.adapt_to_telegram(file_state),
         {:ok, file_state} <- send_file(chat_id, file_state) do
      Lolek.File.move_to_ready_to_telegram(file_state)
    else
      {:error, :no_url} ->
        :ok

      error ->
        stacktrace = Process.info(self(), :current_stacktrace)

        Logger.warning(
          "Error when processing: #{inspect(error)}, stacktrace: #{inspect(stacktrace)}"
        )
    end
  end

  def handle(_, _context) do
    :ok
  end

  defp send_file(chat_id, {:ready_to_telegram, file_path}) do
    extname = Path.extname(file_path) |> String.downcase()
    file_id = Path.basename(file_path, extname)

    case extname do
      ".mp4" ->
        ExGram.send_video!(chat_id, file_id, disable_notification: true)

      _ ->
        ExGram.send_document!(chat_id, file_id)
    end

    {:ok, {:ready_to_telegram, file_path}}
  end

  defp send_file(chat_id, {:compressed, file_path}) do
    case Path.extname(file_path) |> String.downcase() do
      ".mp4" ->
        options = get_options(file_path)

        %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} =
          ExGram.send_video!(chat_id, {:file, file_path}, options)

        {:ok, {:sent_to_telegram_at_first, file_path, file_id}}

      _ ->
        %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} =
          ExGram.send_document!(chat_id, {:file, file_path})

        {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
    end
  end

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
      duration when is_integer(duration) ->
        options ++ [duration: duration]

      _ ->
        options
    end
  end
end
