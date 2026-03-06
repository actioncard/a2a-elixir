defmodule A2A.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/actioncard/a2a-elixir"
  @a2a_spec_url "https://google.github.io/A2A/"

  def project do
    [
      app: :a2a,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      name: "A2A",
      description: "Elixir implementation of the Agent-to-Agent (A2A) protocol",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_local_path: "priv/plts"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},

      # Optional runtime
      {:plug, "~> 1.16", optional: true},
      {:req, "~> 0.5", optional: true},
      {:bandit, "~> 1.5", optional: true},

      # Dev/test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      "test.ci": ["test --warnings-as-errors"]
    ]
  end

  defp package do
    [
      name: "a2a",
      maintainers: ["Action Card AB"],
      licenses: ["Apache-2.0"],
      files:
        ~w(lib examples .formatter.exs mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md SPEC.md),
      links: %{
        "GitHub" => @source_url,
        "A2A Spec" => @a2a_spec_url
      }
    ]
  end

  defp docs do
    [
      main: "A2A",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SPEC.md", "LICENSE"],
      groups_for_modules: [
        Core: [~r/A2A$/],
        Storage: [~r/A2A\.TaskStore/],
        HTTP: [~r/A2A\.(Plug|Client)/]
      ]
    ]
  end
end
