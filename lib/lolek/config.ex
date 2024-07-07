defmodule Lolek.Config do
  @behaviour :dotenv_config_parser

  @impl true
  @spec get_parser() :: :dotenv_config.parser()
  def get_parser() do
    [
      {"LOLEK_BOT_TOKEN", :str}
    ]
  end
end
