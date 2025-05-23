import Config

files = ["config/.env.default", "config/.env"] |> Enum.filter(&File.exists?/1)
:dotenv_config.init(Lolek.Config, files)

config :ex_gram, token: :dotenv_config.get("LOLEK_BOT_TOKEN")

config :lolek, :bot_token, :dotenv_config.get("LOLEK_BOT_TOKEN")

config :lolek, :download_path, :dotenv_config.get("LOLEK_DOWNLOAD_DIR_PATH")

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
