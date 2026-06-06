defmodule Lolek.Config do
  @moduledoc """
  This module is responsible for providing configuration parser for the dotenv_config library.
  """
  @behaviour :dotenv_config_parser

  @impl true
  @spec get_parser() :: :dotenv_config.parser()
  def get_parser() do
    [
      {"LOLEK_TELEGRAM_BASE_URL", :str},
      {"LOLEK_TELEGRAM_LOCAL_FILE_UPLOADS", :bool},
      {"LOLEK_METRICS_ENABLED", :bool},
      {"LOLEK_METRICS_LISTEN_ADDRESS", :str},
      {"LOLEK_METRICS_PORT", :int},
      {"LOLEK_POST_SOURCE_CAPTION", :bool},
      {"LOLEK_DOWNLOAD_DIR_PATH", :str},
      {"LOLEK_MAX_DOWNLOAD_DIR_SIZE", :int},
      {"LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_FILE_SIZE_TO_COMPRESS", :int},
      {"LOLEK_MAX_DURATION_TO_COMPRESS", :int},
      {"LOLEK_MAX_CONCURRENT_DOWNLOADS", :int},
      {"LOLEK_MAX_CONCURRENT_DOWNLOADS_PER_CHAT", :int},
      {"LOLEK_MAX_VIDEO_REQUESTS_PER_CHAT_PER_MINUTE", :int},
      {"LOLEK_DOWNLOAD_COMMAND_TIMEOUT_SECONDS", :int},
      {"LOLEK_CONVERT_COMMAND_TIMEOUT_SECONDS", :int},
      {"LOLEK_PROBE_COMMAND_TIMEOUT_SECONDS", :int},
      {"LOLEK_HW_ACCELERATION", :str},
      {"LOLEK_HW_DEVICE", :str},
      {"LOLEK_ALLOWED_URLS_REGEX", :str},
      {"LOLEK_MAX_DOWNLOAD_TRIES", :int},
      {"LOLEK_START_DOWNLOAD_PAUSE", :int},
      {"LOLEK_MAX_DOWNLOAD_PAUSE", :int}
    ]
  end

  @spec get_bot_token([String.t()]) :: String.t()
  def get_bot_token(files) do
    case System.get_env("LOLEK_BOT_TOKEN_FILE") do
      path when path in [nil, ""] ->
        System.get_env("LOLEK_BOT_TOKEN") || get_bot_token_from_files(files) ||
          raise "Can't find config item: LOLEK_BOT_TOKEN"

      path ->
        path |> File.read!() |> String.trim()
    end
  end

  @spec get_bot_token_from_files([String.t()]) :: String.t() | nil
  defp get_bot_token_from_files(files) do
    files
    |> Enum.reduce(%{}, fn file, config ->
      case :dotenv_config_parser.parse_file(file) do
        {:ok, file_config} -> Map.merge(config, file_config)
        {:error, _reason} -> config
      end
    end)
    |> Map.get("LOLEK_BOT_TOKEN")
    |> normalize_bot_token()
  end

  @spec normalize_bot_token(binary() | nil) :: String.t() | nil
  defp normalize_bot_token(nil), do: nil

  defp normalize_bot_token(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end
