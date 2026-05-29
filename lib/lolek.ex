defmodule Lolek do
  @moduledoc """
  This module is the main module of the Lolek bot containing bot operations
  """

  @spec send_file(integer(), Lolek.File.file_state()) ::
          {:ok, Lolek.File.file_state()} | {:error, term()}
  def send_file(chat_id, {:ready_to_telegram, file_path}) do
    extname = Path.extname(file_path) |> String.downcase()
    file_id = Path.basename(file_path, extname)

    with {:ok, _response} <- send_ready_file(chat_id, file_id, extname) do
      {:ok, {:ready_to_telegram, file_path}}
    end
  end

  def send_file(chat_id, {:compressed, file_path}) do
    case Path.extname(file_path) |> String.downcase() do
      ".mp4" ->
        options = get_options(file_path)

        with {:ok, %ExGram.Model.Message{video: %ExGram.Model.Video{file_id: file_id}}} <-
               call_telegram(fn ->
                 Lolek.Telegram.send_video(chat_id, {:file, file_path}, options)
               end) do
          {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
        else
          {:ok, response} -> {:error, {:unexpected_telegram_response, response}}
          {:error, _reason} = error -> error
        end

      _ ->
        with {:ok, %ExGram.Model.Message{document: %ExGram.Model.Document{file_id: file_id}}} <-
               call_telegram(fn -> Lolek.Telegram.send_document(chat_id, {:file, file_path}) end) do
          {:ok, {:sent_to_telegram_at_first, file_path, file_id}}
        else
          {:ok, response} -> {:error, {:unexpected_telegram_response, response}}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec send_ready_file(integer(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defp send_ready_file(chat_id, file_id, ".mp4") do
    call_telegram(fn ->
      Lolek.Telegram.send_video(chat_id, file_id, disable_notification: true)
    end)
  end

  defp send_ready_file(chat_id, file_id, _extname) do
    call_telegram(fn -> Lolek.Telegram.send_document(chat_id, file_id) end)
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
