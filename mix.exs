defmodule Lolek.MixProject do
  use Mix.Project

  def project do
    [
      app: :lolek,
      version: "3.0.0",
      elixir: "1.20.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Lolek.Application, []}
    ]
  end

  defp aliases do
    [
      test: ["test --no-start"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_gram, "0.66.0"},
      {:tesla, "1.20.0"},
      {:hackney, "1.25.0"},
      {:jason, "1.4.5"},
      {:dotenv_config, "2.3.3"},
      {:erlexec, "2.3.2"},
      {:ex_check, "0.16.0", only: [:dev, :test], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:doctor, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:gettext, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
