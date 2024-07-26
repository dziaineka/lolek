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
        {:text, text, %ExGram.Model.Message{chat: %ExGram.Model.Chat{id: chat_id}}},
        _context
      ) do
    with {:ok, url} <- Lolek.Url.extract_url(text),
         {:ok, folder_path} <- Lolek.File.get_folder_path(url),
         {:ok, file_state} <- Lolek.File.get_file_state(folder_path),
         {:ok, file_state} <- Lolek.Downloader.download(url, file_state),
         {:ok, file_state} <- Lolek.Converter.adapt_to_telegram(file_state),
         {:ok, file_state} <- Lolek.send_file(chat_id, file_state) do
      Lolek.File.move_to_ready_to_telegram(file_state)
    else
      {:error, :no_url} ->
        :ok

        # error ->
        #   stacktrace = Process.info(self(), :current_stacktrace)

        #   Logger.warning(
        #     "Error when processing: #{inspect(error)}, stacktrace: #{inspect(stacktrace)}"
        #   )
    end
  end

  def handle(_, _context) do
    :ok
  end
end
