import Config

:dotenv_config.init(
  Lolek.Config,
  ["config/.env.default", "config/.env"]
)

config :ex_gram, token: :dotenv_config.get("LOLEK_BOT_TOKEN")

config :lolek, :bot_token, :dotenv_config.get("LOLEK_BOT_TOKEN")

config :lolek, :download_path, :dotenv_config.get("LOLEK_DOWNLOAD_DIR_PATH")

:dotenv_config.stop()
