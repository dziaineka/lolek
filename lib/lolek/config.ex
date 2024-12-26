defmodule Lolek.Config do
  @moduledoc """
  This module is responsible for providing configuration parser for the dotenv_config library.
  """
  @behaviour :dotenv_config_parser

  @impl true
  @spec get_parser() :: :dotenv_config.parser()
  def get_parser() do
    [
      {"LOLEK_BOT_TOKEN", :str},
      {"LOLEK_DOWNLOAD_DIR_PATH", :str},
      {"LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM", :int},
      {"LOLEK_MAX_FILE_SIZE_TO_COMPRESS", :int},
      {"LOLEK_MAX_DURATION_TO_COMPRESS", :int},
      {"LOLEK_ALLOWED_URLS_REGEX", :str},
      {"LOLEK_MAX_DOWNLOAD_TRIES", :int},
      {"LOLEK_START_DOWNLOAD_PAUSE", :int},
      {"LOLEK_MAX_DOWNLOAD_PAUSE", :int}
    ]
  end
end
