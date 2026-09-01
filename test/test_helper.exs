# Integration tests need a real Postgres — partitioning and ON CONFLICT
# behaviour cannot be verified against anything else. When one is not
# reachable the suite still runs; those tests are excluded and say so.
alias Ecto.Adapters.Postgres, as: PGAdapter

repo = Pixelex.Test.Repo
config = Application.get_env(:pixelex, repo)

Code.require_file("support/migration.exs", __DIR__)

exclude =
  try do
    _ = PGAdapter.storage_up(config)

    {:ok, _} = repo.start_link(config)

    # Before the migration, not after: Pixelex.Migration.up/0 finishes by
    # creating the first partitions, and that goes through the configured repo.
    Application.put_env(:pixelex, :repo, repo)

    Ecto.Migrator.run(repo, [{0, Pixelex.Test.Migration}], :down, all: true, log: false)
    Ecto.Migrator.run(repo, [{0, Pixelex.Test.Migration}], :up, all: true, log: false)
    # No Ecto sandbox on purpose: these tests create and DROP partitions, and
    # DDL inside a transaction that gets rolled back proves nothing about what
    # production does. Integration tests clean up their own rows.
    []
  rescue
    e ->
      IO.puts("""

      [pixelex] Postgres not available — skipping integration tests.
                #{Exception.message(e)}
      """)

      [integration: true]
  end

ExUnit.start(exclude: exclude)
