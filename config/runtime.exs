import Config

:dotenv_config.init(
  Lolek.Config,
  ["config/.env.default", "config/.env"]
)

config :lolek, :bot_token, :dotenv_config.fetch("LOLEK_BOT_TOKEN")

:dotenv_config.stop()
