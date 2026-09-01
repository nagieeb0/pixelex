import Config

if config_env() == :test do
  # No database in the unit suite: the ETS adapter is the second implementation
  # that proves the Store behaviour is a real seam, so exercising it here is
  # coverage, not a shortcut.
  config :pixelex,
    store: Pixelex.Store.ETS,
    # The repo-backed default would log a warning per refresh in the unit suite,
    # where there is deliberately no repo. Integration tests set :repo back.
    salt_persistence: :memory,
    flush_ms: 50,
    flush_bytes: 1_000_000,
    max_buffer: 200

  config :logger, level: :warning

  # Integration tests only. `mix test` skips them when this database is not
  # reachable, so the unit suite stays runnable with no Postgres at all.
  config :pixelex, Pixelex.Test.Repo,
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: System.get_env("PGHOST", "localhost"),
    database: System.get_env("PGDATABASE", "pixelex_test"),
    pool_size: 5,
    log: false
end
