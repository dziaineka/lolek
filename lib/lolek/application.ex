defmodule Lolek.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  @spec start(any(), any()) :: Supervisor.on_start()
  def start(_type, _args) do
    token = Application.fetch_env!(:lolek, :bot_token)

    children = [
      ExGram,
      {Lolek.Bot, [method: :polling, token: token]},
      Lolek.FileCleaner
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lolek.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
