defmodule Pixelex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nagieeb0/pixelex"

  def project do
    [
      app: :pixelex,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], ignore_warnings: ".dialyzer_ignore.exs"],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Pixelex",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Pixelex.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core. Ecto is required because the shipped store is Postgres; a host app
      # bringing its own adapter still needs the schema definitions.
      {:ecto_sql, "~> 3.10"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # The attribution engine. Both are Apache-2.0 and DOWNLOAD their databases
      # rather than bundling them (`mix ref_inspector.download`), which is what
      # keeps pixelex clear of referers.yml's GPL-3.0.
      #
      # OPTIONAL, reluctantly. They are the engine behind "knows where the
      # visitor came from without UTM", so the installer adds both to the host
      # app by default and `Pixelex.Enrich` warns once at boot when they are
      # missing. But both depend on `hackney ~> 1.0`, and hackney 1.25.0 — the
      # last of the 1.x line — carries four unpatched advisories including
      # EEF-CVE-2026-47071 (HIGH). The fixes exist only in hackney 4.x, which
      # `~> 1.0` cannot resolve to. Requiring these would put a HIGH advisory in
      # every consumer's `mix hex.audit` for a build-time downloader that fetches
      # two files from hardcoded URLs. That is not a trade a new library gets to
      # make for its users. Make them optional and let them opt in.
      {:ref_inspector, "~> 2.0", optional: true},
      {:ua_inspector, "~> 3.0", optional: true},

      # Everything a host app already has, or only needs for one surface.
      {:postgrex, "~> 0.17", optional: true},
      {:plug, "~> 1.14", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true},
      {:oban, "~> 2.17", optional: true},
      {:req, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Cookieless, multi-tenant, first-party analytics for Phoenix: web visitors, " <>
      "product events and ad-platform attribution over one event log."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv assets .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Public API": [Pixelex, Pixelex.Event],
        Identity: [Pixelex.Identity, Pixelex.Identity.Salts, Pixelex.Consent],
        Attribution: [Pixelex.Attribution, Pixelex.Attribution.ClickIds],
        Ingest: [Pixelex.Ingest, Pixelex.Ingest.Buffer, Pixelex.Ingest.Pipeline],
        Storage: [Pixelex.Store, Pixelex.Store.Postgres, Pixelex.Store.ETS]
      ]
    ]
  end
end
