defmodule Pixelex.Store.PostgresTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Pixelex.{Event, Partitions, Store}
  alias Pixelex.Test.Repo

  setup do
    Repo.query!("DELETE FROM pixelex_events")
    Application.put_env(:pixelex, :store, Store.Postgres)
    on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)
    :ok
  end

  defp event(attrs \\ %{}) do
    {:ok, e} = Event.new(Map.merge(%{site_id: "site-a", name: "px.pageview"}, attrs))
    e
  end

  defp count, do: Repo.query!("SELECT count(*) FROM pixelex_events").rows |> hd() |> hd()

  defp partition_names, do: Partitions.existing_partitions() |> Enum.map(&elem(&1, 0))

  describe "schema" do
    test "the events table is range-partitioned, not a plain table" do
      %{rows: [[strategy]]} =
        Repo.query!("SELECT partstrat FROM pg_partitioned_table pt
                     JOIN pg_class c ON c.oid = pt.partrelid
                     WHERE c.relname = 'pixelex_events'")

      assert strategy == "r", "must be RANGE partitioned; converting later locks the table"
    end

    test "indexes are declared on the parent so new partitions inherit them" do
      %{rows: rows} =
        Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'pixelex_events'")

      names = List.flatten(rows)
      assert "pixelex_events_site_time_idx" in names
      assert "pixelex_events_site_name_time_idx" in names
      assert "pixelex_events_site_visitor_time_idx" in names
    end

    test "a partition created now inherits the parent's indexes" do
      [name | _] = partition_names()

      %{rows: rows} = Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = $1", [name])

      assert length(List.flatten(rows)) >= 4,
             "partition #{name} is missing inherited indexes - writes would be unindexed"
    end
  end

  describe "insert_events/1" do
    test "writes a batch and reports how many rows landed" do
      assert {:ok, 3} = Store.Postgres.insert_events([event(), event(), event()])
      assert count() == 3
    end

    test "a replayed batch collides instead of duplicating" do
      e = event()
      assert {:ok, 1} = Store.Postgres.insert_events([e])
      assert {:ok, 0} = Store.Postgres.insert_events([e])
      assert count() == 1
    end

    test "round-trips every field, including jsonb and the render tag" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      e =
        event(%{
          name: "purchase",
          timestamp: now,
          client_ts: now,
          visitor_id: "v1",
          session_id: "s1",
          user_id: "u1",
          url: "https://x.test/a?b=c",
          pathname: "/a",
          hostname: "x.test",
          referrer: "https://google.com/",
          attribution: %{"last" => %{"network" => "meta", "click_id" => "abc"}},
          country: "EG",
          city: "Cairo",
          browser: "Chrome",
          os: "Android",
          device_type: "smartphone",
          render: :connected,
          props: %{"value" => 149.5, "currency" => "EGP"}
        })

      assert {:ok, 1} = Store.Postgres.insert_events([e])

      %{rows: [row]} =
        Repo.query!("""
        SELECT name, visitor_id, user_id, referrer, attribution, country,
               device_type, render, props, v
        FROM pixelex_events
        """)

      assert [
               "purchase",
               "v1",
               "u1",
               "https://google.com/",
               %{"last" => %{"network" => "meta", "click_id" => "abc"}},
               "EG",
               "smartphone",
               "connected",
               %{"value" => 149.5, "currency" => "EGP"},
               1
             ] = row
    end

    test "a batch far beyond Postgres's bind-parameter limit still writes" do
      # 65,535 parameters / 22 columns per row = 2,978 rows per statement.
      # A single insert_all of the default 50,000-event buffer raises and drops
      # the pooled connection, so every flush under load would fail, retry, and
      # be dropped. Only a batch this size shows it.
      events = for _ <- 1..7_000, do: event()

      assert {:ok, 7_000} = Store.Postgres.insert_events(events)
      assert count() == 7_000
    end

    test "the column count the chunk size is derived from is the real one" do
      %{rows: [[columns]]} =
        Repo.query!(
          "SELECT count(*) FROM information_schema.columns WHERE table_name = 'pixelex_events'"
        )

      # If a column is added without updating @columns, the chunk size stops
      # being safe and the bug returns at a slightly smaller batch.
      assert Store.Postgres.max_rows_per_statement() <= div(65_535, columns),
             "pixelex_events now has #{columns} columns; update @columns in Store.Postgres"
    end

    test "an empty batch is a no-op, not an error" do
      assert {:ok, 0} = Store.insert_events([])
    end

    test "a timestamp outside every partition returns an error rather than raising" do
      # The failure mode worth knowing: range partitioning has no catch-all, so
      # an event dated years out has nowhere to go. It must not take the batch
      # or the caller down with it.
      far = DateTime.add(DateTime.utc_now(), 365 * 5, :day)

      assert {:error, _} = Store.Postgres.insert_events([event(%{timestamp: far})])
    end
  end

  describe "partitions" do
    test "ensure/1 is idempotent and creates the months it says it does" do
      :ok = Partitions.ensure(3)
      after_first = length(partition_names())

      :ok = Partitions.ensure(3)
      assert length(partition_names()) == after_first
      assert after_first >= 4, "current month plus three ahead"
    end

    test "partition names and bounds line up with their month" do
      :ok = Partitions.ensure(2)

      for {name, upper} <- Partitions.existing_partitions() do
        assert [_, year, month] = Regex.run(~r/pixelex_events_(\d{4})_(\d{2})$/, name)
        start = Date.new!(String.to_integer(year), String.to_integer(month), 1)

        assert upper == start |> Date.end_of_month() |> Date.add(1),
               "#{name} upper bound #{upper} does not end its month"
      end
    end

    test "the planner prunes partitions for a bounded range" do
      :ok = Partitions.ensure(3)

      from = DateTime.utc_now()
      to = DateTime.add(from, 1, :day)

      %{rows: rows} =
        Repo.query!(
          """
          EXPLAIN SELECT * FROM pixelex_events
          WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
          """,
          ["site-a", from, to]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")
      scanned = Regex.scan(~r/pixelex_events_\d{4}_\d{2}/, plan) |> List.flatten() |> Enum.uniq()

      assert length(scanned) <= 2,
             "a one-day window touched #{length(scanned)} partitions:\n#{plan}"
    end

    test "drop_expired/1 removes only partitions entirely past the cutoff" do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS pixelex_events_2020_01
        PARTITION OF pixelex_events FOR VALUES FROM ('2020-01-01') TO ('2020-02-01')
      """)

      old = event(%{timestamp: ~U[2020-01-15 00:00:00Z]})
      assert {:ok, 1} = Store.Postgres.insert_events([old])
      assert "pixelex_events_2020_01" in partition_names()

      dropped = Partitions.drop_expired(90)

      assert "pixelex_events_2020_01" in dropped
      refute "pixelex_events_2020_01" in partition_names()

      # Dropping the partition took its rows with it. That IS the retention
      # mechanism, not a side effect of one.
      assert count() == 0
    end

    test "drop_expired/1 spares a partition that still holds in-window rows" do
      :ok = Partitions.ensure(1)
      today = Date.utc_today()
      this_month = "pixelex_events_#{today.year}_#{String.pad_leading("#{today.month}", 2, "0")}"

      dropped = Partitions.drop_expired(90)

      refute this_month in dropped
      assert this_month in partition_names()
    end
  end
end
