defmodule Pixelex.Migration do
  @moduledoc """
  Schema, installed from a migration in the host application:

      defmodule MyApp.Repo.Migrations.AddPixelex do
        use Ecto.Migration

        def up, do: Pixelex.Migration.up()
        def down, do: Pixelex.Migration.down()
      end

  The same shape Oban and `error_tracker` use: the library owns the DDL, the
  host owns when it runs.

  ## Why `pixelex_events` is partitioned from the first migration

  Converting a populated table to a partitioned one later means copying every
  row under an exclusive lock. On the one table that grows fastest, that is the
  migration nobody ever runs — so the table is born partitioned, even on a site
  with a hundred events.

  Partitions are created by `Pixelex.Partitions.ensure/1`, which this migration
  calls for the current and next month. Keeping it running is the host's job;
  see that module.
  """
  use Ecto.Migration

  @events "pixelex_events"
  @sites "pixelex_sites"
  @salts "pixelex_salts"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{@events} (
      id          uuid        NOT NULL,
      v           smallint    NOT NULL DEFAULT 1,
      site_id     text        NOT NULL,
      name        text        NOT NULL,
      occurred_at timestamptz NOT NULL,
      client_ts   timestamptz,
      visitor_id  text,
      session_id  text,
      user_id     text,
      url         text,
      pathname    text,
      hostname    text,
      referrer    text,
      attribution jsonb,
      country     text,
      region      text,
      city        text,
      browser     text,
      os          text,
      device_type text,
      render      text,
      props       jsonb       NOT NULL DEFAULT '{}'::jsonb,
      PRIMARY KEY (id, occurred_at)
    ) PARTITION BY RANGE (occurred_at)
    """)

    # Declared on the parent, so every partition inherits them and a partition
    # created next year is not silently unindexed.
    #
    # Each one answers a question the dashboard actually asks; there is no
    # index here on a column nothing filters by, because on this table an
    # unused index is pure write cost forever.
    execute(
      "CREATE INDEX IF NOT EXISTS #{@events}_site_time_idx ON #{@events} (site_id, occurred_at DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS #{@events}_site_name_time_idx ON #{@events} (site_id, name, occurred_at DESC)"
    )

    # Funnels and sessionisation walk one visitor's events in order.
    execute(
      "CREATE INDEX IF NOT EXISTS #{@events}_site_visitor_time_idx ON #{@events} (site_id, visitor_id, occurred_at)"
    )

    # Partial: most rows have no user_id, and retention/cohort queries only ever
    # ask about the ones that do.
    execute("""
    CREATE INDEX IF NOT EXISTS #{@events}_site_user_time_idx
      ON #{@events} (site_id, user_id, occurred_at) WHERE user_id IS NOT NULL
    """)

    create_if_not_exists table(@sites, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:domain, :text)
      # Which event names an unauthenticated browser may write. Per-site and in
      # the database, not in application config: a library cannot know a
      # tenant's events at compile time, and an open endpoint with no allowlist
      # is a table anyone on the internet can fill.
      add(:allowed_events, {:array, :text}, null: false, default: [])
      # nil means "allowlist enforced". Set for trusted server-side-only sites.
      add(:allow_any_event, :boolean, null: false, default: false)
      add(:destinations, :map, null: false, default: %{})
      add(:retention_days, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    # Keyed by the UTC day, not a serial. That one choice removes the scheduler:
    # rotation becomes `INSERT ... ON CONFLICT DO NOTHING` for today's date, so
    # whichever node notices the new day first wins and every other node reads
    # the winner's salt. No cron to forget, no leader election, and no window
    # where two nodes hash the same visitor differently.
    create_if_not_exists table(@salts, primary_key: false) do
      add(:day, :date, primary_key: true)
      add(:salt, :binary, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    flush()

    # A partitioned table with no partitions rejects every insert, so the first
    # two exist before this migration returns.
    Pixelex.Partitions.ensure(1)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{@events} CASCADE")
    drop_if_exists(table(@salts))
    drop_if_exists(table(@sites))
  end
end
