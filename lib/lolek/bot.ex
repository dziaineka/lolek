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

  def handle({:text, text, %ExGram.Model.Message{chat: %ExGram.Model.Chat{id: chat_id}}}, _context) do
    with {:ok, url} <- Lolek.Url.extract_url(text),
         {:ok, file_path} <- Lolek.Downloader.download(url) do
      send_file(chat_id, file_path)
    else
      {:error, :no_url} ->
        :ok

      {:error, reason} ->
        Logger.warning("Error when downloading: #{inspect(reason)}")
    end
  end

  defp send_file(chat_id, {:existed, file_path}) do
    extname = Path.extname(file_path)
    file_id = Path.basename(file_path, extname)

    case extname do
      ".mp4" ->
        ExGram.send_video!(chat_id, file_id)

      _ ->
        ExGram.send_document!(chat_id, file_id)
    end
  end

  defp send_file(chat_id, file_path) do
    file_id =
      case Path.extname(file_path) do
        ".mp4" ->
          %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} =
            ExGram.send_video!(chat_id, {:file, file_path})

          file_id

        _ ->
          %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} =
            ExGram.send_document!(chat_id, {:file, file_path})

          file_id
      end

    file_extension = Path.extname(file_path)
    new_file_path = file_path |> Path.dirname() |> Path.join(file_id <> file_extension)
    File.rename(file_path, new_file_path)
  end
end
