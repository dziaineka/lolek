defmodule Lolek.MixProject do
  use Mix.Project

  def project do
    [
      app: :lolek,
      version: "6.2.0",
      elixir: "1.20.5",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # test_helper.exs loads the test support files.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")]
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
      {:ex_gram, "0.71.0"},
      {:req, "0.7.5", override: true},
      {:html_entities, "0.5.2"},
      {:jason, "1.4.5"},
      {:erlexec, "2.6.0"},
      {:ex_check, "0.17.1", only: [:dev, :test], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:doctor, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:gettext, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
