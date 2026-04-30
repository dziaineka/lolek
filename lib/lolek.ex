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
        call_telegram(fn -> ExGram.send_video!(chat_id, file_id, disable_notification: true) end)

      _ ->
        call_telegram(fn -> ExGram.send_document!(chat_id, file_id) end)
    end

    {:ok, {:ready_to_telegram, file_path}}
  end

  def send_file(chat_id, {:compressed, file_path}) do
    case Path.extname(file_path) |> String.downcase() do
      ".mp4" ->
        options = get_options(file_path)

        %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}} =
          call_telegram(fn -> ExGram.send_video!(chat_id, {:file, file_path}, options) end)

        {:ok, {:sent_to_telegram_at_first, file_path, file_id}}

      _ ->
        %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}} =
          call_telegram(fn -> ExGram.send_document!(chat_id, {:file, file_path}) end)

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

  @spec call_telegram((-> term())) :: term() | no_return()
  defp call_telegram(fun) do
    fun.()
  rescue
    error in ExGram.Error ->
      reraise RuntimeError,
              [message: "Telegram API request failed: #{inspect(error.code)}"],
              __STACKTRACE__
  end
end
