defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """

  @spec send_file(integer(), Lolek.File.file_state()) :: {:ok, Lolek.File.file_state()}
  def send_file(chat_id, {:ready_to_telegram, file_path}) do
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

  def send_file(chat_id, {:compressed, file_path}) do
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
end
