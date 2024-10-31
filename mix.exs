defmodule PGZero.MixProject do
  use Mix.Project

  def project do
    [
      app: :pgzero,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths:
        ["lib"] ++
          if Mix.env() == :test do
            ["test/support"]
          else
            []
          end
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # mod: {PGZeroAgent, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      # , only: :test}
      {:local_cluster, "~> 2.1.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
