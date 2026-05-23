defmodule EventSales.MixProject do
  use Mix.Project

  def project do
    [
      app: :event_sales,
      version: "0.1.0",
      elixir: "1.19.3",
      erlang: "28.1.1",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EventSales.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [
        {:precommit, :test},
        {:dialyzer, :test},
        {:"quality.fast", :test},
        {:"quality.pr", :test},
        {:quality, :test},
        {:"quality.ci", :test}
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ash, "~> 3.24"},
      {:ash_postgres, "~> 2.9"},
      {:ash_authentication, "~> 4.13"},
      {:ash_admin, "~> 1.1"},
      {:ash_state_machine, "~> 0.2.13"},
      {:ash_paper_trail, "~> 0.5.7"},
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.11.1"},
      {:oban, "~> 2.22"},
      {:oban_web, "~> 2.12"},
      {:nimble_csv, "~> 1.3"},
      {:redix, "~> 1.5"},
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false},
      {:owl, "~> 0.13", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["test"],
      precommit: ["quality.fast"],
      "quality.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd bash scripts/check_no_web_woocommerce_refs.sh"
      ],
      "quality.pr": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd bash scripts/check_no_web_woocommerce_refs.sh",
        "ash.codegen --dry-run",
        "cmd git diff --exit-code priv/repo/migrations priv/resource_snapshots",
        "credo --strict",
        "test"
      ],
      quality: ["quality.fast", "credo --strict", "sobelow"],
      "quality.ci": [
        "deps.get --check-locked",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd bash scripts/check_no_web_woocommerce_refs.sh",
        "ash.codegen --dry-run",
        "cmd git diff --exit-code priv/repo/migrations priv/resource_snapshots",
        "credo --strict",
        "sobelow",
        "deps.audit",
        "cmd mix hex.audit",
        "test",
        "dialyzer"
      ]
    ]
  end
end
