import Config

files = ["config/.env.default", "config/.env"] |> Enum.filter(&File.exists?/1)
:dotenv_config.init(Lolek.Config, files)

bot_token =
  case System.get_env("LOLEK_BOT_TOKEN_FILE") do
    path when path in [nil, ""] -> :dotenv_config.get("LOLEK_BOT_TOKEN")
    path -> path |> File.read!() |> String.trim()
  end

config :ex_gram,
  token: bot_token,
  base_url: :dotenv_config.get("LOLEK_TELEGRAM_BASE_URL")

config :lolek, :bot_token, bot_token

config :lolek, :download_path, :dotenv_config.get("LOLEK_DOWNLOAD_DIR_PATH")

config :lolek,
       :max_download_dir_size,
       :dotenv_config.get("LOLEK_MAX_DOWNLOAD_DIR_SIZE")

config :lolek,
       :max_file_size_to_send_to_telegram,
       :dotenv_config.get("LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM")

config :lolek,
       :max_video_size_to_send_to_telegram,
       :dotenv_config.get("LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM")

config :lolek,
       :max_audio_size_to_send_to_telegram,
       :dotenv_config.get("LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM")

config :lolek,
       :max_file_size_to_compress,
       :dotenv_config.get("LOLEK_MAX_FILE_SIZE_TO_COMPRESS")

config :lolek,
       :max_duration_to_compress,
       :dotenv_config.get("LOLEK_MAX_DURATION_TO_COMPRESS")

config :lolek,
       :max_concurrent_downloads,
       :dotenv_config.get("LOLEK_MAX_CONCURRENT_DOWNLOADS")

config :lolek,
       :max_concurrent_downloads_per_chat,
       :dotenv_config.get("LOLEK_MAX_CONCURRENT_DOWNLOADS_PER_CHAT")

config :lolek,
       :download_command_timeout_seconds,
       :dotenv_config.get("LOLEK_DOWNLOAD_COMMAND_TIMEOUT_SECONDS")

config :lolek,
       :convert_command_timeout_seconds,
       :dotenv_config.get("LOLEK_CONVERT_COMMAND_TIMEOUT_SECONDS")

config :lolek,
       :probe_command_timeout_seconds,
       :dotenv_config.get("LOLEK_PROBE_COMMAND_TIMEOUT_SECONDS")

config :lolek,
       :allowed_urls_regex,
       :dotenv_config.get("LOLEK_ALLOWED_URLS_REGEX")

config :lolek,
       :max_download_tries,
       :dotenv_config.get("LOLEK_MAX_DOWNLOAD_TRIES")

config :lolek,
       :start_download_pause,
       :dotenv_config.get("LOLEK_START_DOWNLOAD_PAUSE")

config :lolek,
       :max_download_pause,
       :dotenv_config.get("LOLEK_MAX_DOWNLOAD_PAUSE")

:dotenv_config.stop()
