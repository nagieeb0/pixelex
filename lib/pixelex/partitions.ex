defmodule Pixelex.Partitions do
  @moduledoc """
  Monthly partitions for `pixelex_events`: create them ahead of time, drop them
  when they age out.

  ## Why this has to be scheduled

  A range-partitioned table with no partition covering `now()` rejects every
  insert. Nothing degrades gracefully — ingestion simply stops at midnight on
  the first of the month. So `ensure/1` runs ahead, and it must keep running:

      # with Oban
      config :my_app, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", Pixelex.Partitions.Worker}]}]

  `ensure/1` is idempotent, so running it hourly is fine and running it on boot
  is a reasonable belt-and-braces.

  ## Retention

  `drop_expired/1` drops whole partitions whose entire range is older than the
  cutoff. `DELETE FROM pixelex_events WHERE occurred_at < …` would do the same
  thing by rewriting the largest table in the system and leaving the space to
  vacuum; `DROP TABLE` on a partition returns it to the filesystem immediately.

  The cost is granularity: a partition survives until its *newest* row is
  expired, so with 90-day retention rows live 90–120 days. That is the trade
  monthly partitions make. Weekly partitions tighten it at the cost of more
  relations; set `:partition_period` to `:week` if the policy needs it.
  """
  require Logger

  alias Pixelex.Config

  @table "pixelex_events"

  @doc """
  Create partitions covering this month and `ahead` further months.

  Idempotent — `CREATE TABLE IF NOT EXISTS`.
  """
  @spec ensure(non_neg_integer()) :: :ok
  def ensure(ahead \\ 2) do
    today = Date.utc_today()

    0..ahead
    |> Enum.map(&month_start(today, &1))
    |> Enum.each(&create_partition/1)

    :ok
  end

  @doc """
  Drop every partition whose whole range predates `retention_days` ago.

  Returns the names dropped.
  """
  @spec drop_expired(pos_integer() | nil) :: [String.t()]
  def drop_expired(retention_days \\ nil) do
    days = retention_days || Config.retention_days()
    cutoff = Date.add(Date.utc_today(), -days)

    for {name, upper} <- existing_partitions(),
        Date.compare(upper, cutoff) == :lt do
      sql!(~s(DROP TABLE IF EXISTS "#{name}"))
      Logger.info("Pixelex dropped expired partition #{name} (ended #{upper})")
      name
    end
  end

  @doc "Partition names with the exclusive upper bound of each range."
  @spec existing_partitions() :: [{String.t(), Date.t()}]
  def existing_partitions do
    %{rows: rows} =
      sql!(
        """
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid)
        FROM pg_class c
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = $1
        """,
        [@table]
      )

    rows
    |> Enum.map(fn [name, bound] -> {name, upper_bound(bound)} end)
    |> Enum.reject(fn {_n, upper} -> is_nil(upper) end)
  end

  defp create_partition(%Date{} = start) do
    stop = start |> Date.end_of_month() |> Date.add(1)
    name = "#{@table}_#{start.year}_#{String.pad_leading("#{start.month}", 2, "0")}"

    sql!("""
    CREATE TABLE IF NOT EXISTS "#{name}"
      PARTITION OF #{@table}
      FOR VALUES FROM ('#{start}') TO ('#{stop}')
    """)

    name
  end

  # pixelex has no repo of its own — it borrows the host's, which is also what
  # makes the events land in the same database (and the same backup) as the
  # rows they describe.
  defp sql!(query, params \\ []) do
    repo =
      Config.repo() ||
        raise "Pixelex partition management needs `config :pixelex, repo: MyApp.Repo`"

    Ecto.Adapters.SQL.query!(repo, query, params)
  end

  defp month_start(%Date{} = from, months_ahead) do
    from
    |> Date.beginning_of_month()
    |> add_months(months_ahead)
  end

  defp add_months(date, 0), do: date

  defp add_months(date, n) when n > 0 do
    date
    |> Date.end_of_month()
    |> Date.add(1)
    |> add_months(n - 1)
  end

  # "FOR VALUES FROM ('2026-09-01') TO ('2026-10-01')" -> ~D[2026-10-01]
  defp upper_bound(bound) when is_binary(bound) do
    case Regex.run(~r/TO \('([\d-]+)/, bound) do
      [_, date] -> Date.from_iso8601!(date)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp upper_bound(_), do: nil
end
