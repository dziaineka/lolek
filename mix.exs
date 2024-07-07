defmodule Lolek.MixProject do
  use Mix.Project

  def project do
    [
      app: :lolek,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Lolek.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_gram, "~> 0.53"},
      {:tesla, "~> 1.11"},
      {:hackney, "~> 1.20"},
      {:jason, ">= 1.4.0"}
    ]
  end
end
