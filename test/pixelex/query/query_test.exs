defmodule Pixelex.QueryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Pixelex.{Event, Store}
  alias Pixelex.Query
  alias Pixelex.Query.{Funnel, Interactions, Retention, Traffic}
  alias Pixelex.Test.Repo

  @site "query-test"
  @base ~U[2026-09-01 12:00:00Z]

  setup do
    Repo.query!("DELETE FROM pixelex_events WHERE site_id = $1", [@site])
    Pixelex.Partitions.ensure(1)
    :ok
  end

  # Events are written straight to the store rather than through the pipeline:
  # these tests are about the SQL, and going through ingest would mean fighting
  # session dedup and the salt to place a row at a chosen minute.
  defp write(events) do
    events =
      Enum.map(events, fn attrs ->
        {:ok, event} = Event.new(Map.put_new(attrs, :site_id, @site))
        event
      end)

    {:ok, _n} = Store.Postgres.insert_events(events)
    :ok
  end

  defp at(minutes), do: DateTime.add(@base, minutes, :minute)
  defp range(from_min \\ -60, to_min \\ 600), do: Query.range(at(from_min), at(to_min))

  describe "Query.range/2" do
    test "rejects a backwards window" do
      assert_raise ArgumentError, ~r/must be before/, fn ->
        Query.range(at(10), at(0))
      end
    end

    test "presets are relative to now" do
      r = Query.range(:last_7_days)
      assert Query.days(r) == 7
    end

    test "the bucket follows the window, so a chart never gets 8760 points" do
      assert Query.bucket(Query.range(at(0), at(60))) == "hour"
      assert Query.bucket(Query.range(at(0), at(60 * 24 * 30))) == "day"
      assert Query.bucket(Query.range(at(0), at(60 * 24 * 200))) == "week"
      assert Query.bucket(Query.range(at(0), at(60 * 24 * 500))) == "month"
    end

    test "a bucket cannot be smuggled into date_trunc" do
      assert_raise ArgumentError, fn -> Query.validate_bucket!("day'); DROP TABLE --") end
      assert Query.validate_bucket!("day") == "day"
    end

    test "limits are clamped rather than trusted" do
      assert Query.limit!(nil) == 100
      assert Query.limit!(50) == 50
      assert Query.limit!(999_999) == 10_000
      assert_raise ArgumentError, fn -> Query.limit!(-1) end
      assert_raise ArgumentError, fn -> Query.limit!("all") end
    end
  end

  describe "Traffic" do
    setup do
      write([
        # session 1: two page views and a click — not a bounce
        %{
          name: "px.pageview",
          timestamp: at(0),
          visitor_id: "v1",
          session_id: "s1",
          pathname: "/",
          country: "EG",
          browser: "Chrome",
          device_type: "smartphone",
          attribution: %{"last" => %{"source" => "Google", "medium" => "organic_search"}}
        },
        %{
          name: "px.pageview",
          timestamp: at(1),
          visitor_id: "v1",
          session_id: "s1",
          pathname: "/pricing",
          country: "EG",
          browser: "Chrome",
          device_type: "smartphone",
          attribution: %{"last" => %{"source" => "Google", "medium" => "organic_search"}}
        },
        %{
          name: "book_click",
          timestamp: at(2),
          visitor_id: "v1",
          session_id: "s1",
          pathname: "/pricing",
          country: "EG",
          browser: "Chrome",
          device_type: "smartphone"
        },

        # session 2: one page view — a bounce
        %{
          name: "px.pageview",
          timestamp: at(10),
          visitor_id: "v2",
          session_id: "s2",
          pathname: "/",
          country: "SA",
          browser: "Safari",
          device_type: "desktop",
          attribution: %{
            "last" => %{
              "source" => "facebook",
              "medium" => "paid_social",
              "campaign" => "ramadan",
              "network" => "facebook"
            }
          }
        },

        # session 3: another bounce, different day-bucket
        %{
          name: "px.pageview",
          timestamp: at(200),
          visitor_id: "v3",
          session_id: "s3",
          pathname: "/pricing",
          country: "EG",
          browser: "Chrome",
          device_type: "desktop"
        }
      ])
    end

    test "summary counts views, events, sessions and bounces" do
      s = Traffic.summary(@site, range())

      assert s.pageviews == 4
      assert s.events == 5
      assert s.sessions == 3
      assert s.visitors_daily_sum == 3
      # s2 and s3 saw one page each.
      assert s.bounce_rate == 0.6667
      assert s.views_per_session == 1.3333
    end

    test "the visitor field is named for what it actually is" do
      s = Traffic.summary(@site, range())

      assert Map.has_key?(s, :visitors_daily_sum)

      refute Map.has_key?(s, :visitors),
             "the hash rotates daily, so a field called `visitors` would be a lie over any multi-day range"
    end

    test "top pages are ordered and bounded" do
      assert [%{value: "/pricing", events: 2}, %{value: "/", events: 2}] =
               Enum.sort_by(Traffic.top_pages(@site, range()), & &1.value, :desc)

      assert length(Traffic.top_pages(@site, range(), limit: 1)) == 1
    end

    test "sources and mediums come from the stored attribution" do
      sources = Map.new(Traffic.sources(@site, range()), &{&1.value, &1.events})
      assert sources["Google"] == 2
      assert sources["facebook"] == 1

      mediums = Map.new(Traffic.mediums(@site, range()), &{&1.value, &1.events})
      assert mediums["organic_search"] == 2
      assert mediums["paid_social"] == 1
    end

    test "campaigns carry the network that paid for them" do
      assert [%{campaign: "ramadan", network: "facebook", events: 1}] =
               Traffic.campaigns(@site, range())
    end

    test "countries, browsers and devices group as expected" do
      assert Map.new(Traffic.countries(@site, range()), &{&1.value, &1.events}) ==
               %{"EG" => 4, "SA" => 1}

      assert Map.new(Traffic.devices(@site, range()), &{&1.value, &1.events}) ==
               %{"smartphone" => 3, "desktop" => 2}
    end

    test "custom events exclude page views" do
      assert [%{value: "book_click", events: 1}] = Traffic.events(@site, range())
    end

    test "the timeseries buckets and orders" do
      series = Traffic.timeseries(@site, range(), bucket: "hour")

      assert length(series) >= 2
      assert series == Enum.sort_by(series, & &1.at, NaiveDateTime)
      assert Enum.sum(Enum.map(series, & &1.pageviews)) == 4
    end

    test "nothing outside the window is counted" do
      assert Traffic.summary(@site, Query.range(at(1_000), at(2_000))).pageviews == 0
    end
  end

  describe "Interactions" do
    setup do
      write([
        %{
          name: "px.inventory",
          timestamp: at(0),
          session_id: "s1",
          pathname: "/doctor",
          props: %{
            "interactive" => 3,
            "buttons" => 2,
            "links" => 1,
            "actions" => "booking,contact_whatsapp"
          }
        },
        %{
          name: "px.inventory",
          timestamp: at(1),
          session_id: "s1",
          pathname: "/doctor",
          props: %{
            "interactive" => 4,
            "buttons" => 3,
            "links" => 1,
            "actions" => "booking,contact_whatsapp"
          }
        },
        %{
          name: "px.click",
          timestamp: at(2),
          visitor_id: "v1",
          session_id: "s1",
          pathname: "/doctor",
          props: %{"action" => "booking", "label" => "hero_booking"}
        },
        %{
          name: "px.engagement",
          timestamp: at(3),
          session_id: "s1",
          pathname: "/doctor",
          props: %{"d" => 75, "ms" => 12_500}
        },
        %{
          name: "px.engagement",
          timestamp: at(4),
          session_id: "s2",
          pathname: "/doctor",
          props: %{"d" => 100, "ms" => 7_500}
        }
      ])
    end

    test "returns the latest element inventory for each path" do
      assert [row] = Interactions.inventory(@site, range())
      assert row.path == "/doctor"
      assert row.interactive == 4
      assert row.buttons == 3
      assert row.links == 1
      assert row.actions == "booking,contact_whatsapp"
    end

    test "groups semantic clicks without requiring a developer label" do
      assert [row] = Interactions.clicks(@site, range())

      assert row == %{
               action: "booking",
               label: "hero_booking",
               events: 1,
               sessions: 1,
               visitors: 1
             }
    end

    test "summarises depth and active time" do
      assert %{
               events: 2,
               sessions: 2,
               average_depth: 87.5,
               maximum_depth: 100,
               engaged_ms: 20_000
             } = Interactions.engagement(@site, range())
    end

    test "returns a bounded newest-first timeline" do
      rows = Interactions.timeline(@site, range(), limit: 2)
      assert Enum.map(rows, & &1.name) == ["px.engagement", "px.engagement"]
      assert Enum.map(rows, & &1.at) == Enum.sort(Enum.map(rows, & &1.at), {:desc, DateTime})
    end
  end

  describe "Funnel" do
    setup do
      write([
        # a: clean run through all three
        %{name: "view", timestamp: at(0), visitor_id: "a"},
        %{name: "click", timestamp: at(1), visitor_id: "a"},
        %{name: "buy", timestamp: at(2), visitor_id: "a"},

        # b: stops after the first step
        %{name: "view", timestamp: at(0), visitor_id: "b"},

        # c: does the LAST step first, then the whole funnel properly.
        # The naive single-pass implementation - min(occurred_at) FILTER (...)
        # per step - takes c's earliest `buy` at minute 0, sees it is before the
        # `click`, and drops them. They converted.
        %{name: "buy", timestamp: at(0), visitor_id: "c"},
        %{name: "view", timestamp: at(5), visitor_id: "c"},
        %{name: "click", timestamp: at(6), visitor_id: "c"},
        %{name: "buy", timestamp: at(7), visitor_id: "c"},

        # d: right steps, wrong order, never repeated
        %{name: "click", timestamp: at(0), visitor_id: "d"},
        %{name: "view", timestamp: at(1), visitor_id: "d"},

        # e: identified user, steps spread over three days
        %{name: "view", timestamp: at(0), visitor_id: "e1", user_id: "u1"},
        %{name: "click", timestamp: at(60 * 24), visitor_id: "e2", user_id: "u1"},
        %{name: "buy", timestamp: at(60 * 48), visitor_id: "e3", user_id: "u1"}
      ])
    end

    test "counts an ordered funnel" do
      result = Funnel.run(@site, range(), ~w(view click buy))

      counts = Enum.map(result.steps, & &1.count)

      # view: a, b, c, d, e1  -> 5
      # click after view: a, c  (d clicked first; e's click is a different visitor)
      # buy after click: a, c
      assert counts == [5, 2, 2]
    end

    test "a step done before AND after the previous one still counts" do
      # This is the case the shortcut gets wrong, and it is not exotic — it is
      # any funnel where the last step is also reachable from somewhere else.
      result = Funnel.run(@site, range(), ~w(view click buy))
      completed = List.last(result.steps).count

      assert completed == 2, "visitor c converted on their second pass and must be counted"
    end

    test "steps in the wrong order do not count" do
      # d did click then view and never clicked again.
      result = Funnel.run(@site, range(), ~w(view click))
      assert List.last(result.steps).count == 2
    end

    test "reports rates against the first step and against the previous one" do
      result = Funnel.run(@site, range(), ~w(view click buy))
      [first, second, third] = result.steps

      assert first.rate == 1.0
      assert second.rate == 0.4
      assert second.step_rate == 0.4
      assert third.step_rate == 1.0
      assert result.conversion_rate == 0.4
    end

    test "drop-off is the difference to the next step" do
      [first, second, third] = Funnel.run(@site, range(), ~w(view click buy)).steps

      assert first.dropped == 3
      assert second.dropped == 0
      assert third.dropped == 0
    end

    test "a visitor funnel cannot span days, and a user funnel can" do
      # u1's three steps are a day apart, on three different visitor hashes —
      # which is exactly what the daily salt rotation produces.
      by_visitor = Funnel.run(@site, range(-60, 60 * 72), ~w(view click buy), subject: :visitor)
      by_user = Funnel.run(@site, range(-60, 60 * 72), ~w(view click buy), subject: :user)

      assert List.last(by_visitor.steps).count == 2, "a and c only"
      assert List.last(by_user.steps).count == 1, "u1, whose steps span three days"
      assert by_user.subject == :user
    end

    test "a conversion window bounds how long a step may take" do
      wide = Funnel.run(@site, range(-60, 60 * 72), ~w(view click buy), subject: :user)

      narrow =
        Funnel.run(@site, range(-60, 60 * 72), ~w(view click buy),
          subject: :user,
          within: {1, "hours"}
        )

      assert List.last(wide.steps).count == 1
      assert List.last(narrow.steps).count == 0, "u1 took a day between steps"
    end

    test "a single-step funnel is just a count" do
      assert [%{count: 5, rate: 1.0}] = Funnel.run(@site, range(), ["view"]).steps
    end

    test "refuses input it cannot make safe" do
      assert_raise ArgumentError, ~r/at least one step/, fn -> Funnel.run(@site, range(), []) end

      assert_raise ArgumentError, ~r/capped at 10/, fn ->
        Funnel.run(@site, range(), Enum.map(1..11, &"s#{&1}"))
      end

      assert_raise ArgumentError, ~r/non-empty event names/, fn ->
        Funnel.run(@site, range(), ["ok", ""])
      end

      assert_raise ArgumentError, ~r/subject must be/, fn ->
        Funnel.run(@site, range(), ["view"], subject: :whatever)
      end

      assert_raise ArgumentError, ~r/within must be/, fn ->
        Funnel.run(@site, range(), ["view"], within: {1, "hours'); DROP TABLE --"})
      end
    end

    test "a step name that never occurred is zero, not an error" do
      assert [_, %{count: 0}] = Funnel.run(@site, range(), ~w(view never_happened)).steps
    end
  end

  describe "Retention" do
    setup do
      day = 60 * 24

      write([
        # u1 and u2 appear on day 0; u1 returns on days 1 and 2, u2 on day 1
        %{name: "px.pageview", timestamp: at(0), user_id: "u1", visitor_id: "a1"},
        %{name: "px.pageview", timestamp: at(0), user_id: "u2", visitor_id: "a2"},
        %{name: "px.pageview", timestamp: at(day), user_id: "u1", visitor_id: "b1"},
        %{name: "px.pageview", timestamp: at(day), user_id: "u2", visitor_id: "b2"},
        %{name: "px.pageview", timestamp: at(2 * day), user_id: "u1", visitor_id: "c1"},

        # u3 first appears on day 1 — a different cohort
        %{name: "px.pageview", timestamp: at(day), user_id: "u3", visitor_id: "b3"},

        # an anonymous visitor, who cannot be retained by construction
        %{name: "px.pageview", timestamp: at(0), visitor_id: "anon"}
      ])
    end

    test "builds a daily cohort grid" do
      result = Retention.cohorts(@site, range(-60, 60 * 96), bucket: "day")

      assert result.bucket == "day"
      assert [day0, day1] = result.cohorts

      assert day0.size == 2
      assert Enum.map(day0.periods, &{&1.period, &1.users}) == [{0, 2}, {1, 2}, {2, 1}]
      assert Enum.map(day0.periods, & &1.rate) == [1.0, 1.0, 0.5]

      assert day1.size == 1
      assert Enum.map(day1.periods, &{&1.period, &1.users}) == [{0, 1}]
    end

    test "anonymous visitors are absent, because a rotating hash cannot be retained" do
      result = Retention.cohorts(@site, range(-60, 60 * 96), bucket: "day")
      total = result.cohorts |> Enum.map(& &1.size) |> Enum.sum()

      assert total == 3, "u1, u2, u3 — the anonymous visitor is not a person we can follow"
    end

    test "a site that never calls identify/3 gets empty cohorts, not wrong ones" do
      assert %{cohorts: []} = Retention.cohorts("no-such-site", range(), bucket: "day")
    end

    test "activity can be narrowed to one event" do
      write([%{name: "purchase", timestamp: at(60 * 24), user_id: "u1", visitor_id: "b1"}])

      result = Retention.cohorts(@site, range(-60, 60 * 96), bucket: "day", event: "purchase")

      assert [cohort] = result.cohorts
      assert Enum.map(cohort.periods, &{&1.period, &1.users}) == [{1, 1}]
    end

    test "weekly and monthly buckets count in calendar periods" do
      assert %{bucket: "week"} = Retention.cohorts(@site, range(-60, 60 * 96), bucket: "week")
      assert %{bucket: "month"} = Retention.cohorts(@site, range(-60, 60 * 96), bucket: "month")
    end
  end

  describe "db-perf: every read is bounded" do
    setup do
      write(
        for i <- 1..500 do
          %{
            name: if(rem(i, 5) == 0, do: "book_click", else: "px.pageview"),
            timestamp: at(rem(i, 300)),
            visitor_id: "v#{rem(i, 50)}",
            session_id: "s#{rem(i, 80)}",
            user_id: if(rem(i, 3) == 0, do: "u#{rem(i, 20)}"),
            pathname: "/p#{rem(i, 10)}"
          }
        end
      )

      Repo.query!("ANALYZE pixelex_events")
      :ok
    end

    defp plan(sql, params) do
      Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params).rows
      |> List.flatten()
      |> Enum.join("\n")
    end

    test "a bounded traffic query never scans the whole parent table" do
      p =
        plan(
          """
          SELECT count(*) FROM pixelex_events
          WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
          """,
          [@site, at(-60), at(600)]
        )

      partitions = Regex.scan(~r/pixelex_events_\d{4}_\d{2}/, p) |> List.flatten() |> Enum.uniq()

      assert length(partitions) <= 2, "a ten-hour window touched #{length(partitions)} partitions"

      refute p =~ ~r/Seq Scan on pixelex_events\s/,
             "the parent must never be scanned; only pruned partitions:\n#{p}"

      # Deliberately NOT asserting an index scan, and not asserting a buffer
      # count either. On a few hundred rows in one partition the planner picks
      # a sequential scan and is right to; and the partition is shared with
      # other tests' sites, so any absolute buffer number is a function of
      # execution order rather than of this query. What IS invariant is above:
      # the range prunes to its own partitions and the parent is never scanned.
      # The index path is proven below, at a size where it actually wins.
      assert p =~ "Execution Time"
    end

    @tag :slow
    test "at a size where the index wins, the planner uses it" do
      # Enough rows that a sequential scan of the partition stops being the
      # cheapest option. This is what proves the indexes in the migration are
      # the ones the queries actually need.
      bulk =
        for i <- 1..30_000 do
          {:ok, e} =
            Event.new(%{
              site_id: "bulk-#{rem(i, 40)}",
              name: "px.pageview",
              timestamp: at(rem(i, 400)),
              visitor_id: "v#{rem(i, 3_000)}",
              pathname: "/p#{rem(i, 50)}"
            })

          e
        end

      bulk |> Enum.chunk_every(5_000) |> Enum.each(&Store.Postgres.insert_events/1)
      Repo.query!("ANALYZE pixelex_events")

      on_exit(fn ->
        Repo.query!("DELETE FROM pixelex_events WHERE site_id LIKE 'bulk-%'")
      end)

      p =
        plan(
          """
          SELECT count(*) FROM pixelex_events
          WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
          """,
          ["bulk-7", at(-60), at(600)]
        )

      assert p =~ "Index" or p =~ "Bitmap",
             "one site out of forty, 30k rows, and still no index:\n#{p}"

      refute p =~ ~r/Seq Scan on pixelex_events\s/
    end

    test "the funnel's own query plans without a sequential scan of everything" do
      p =
        plan(
          """
          SELECT visitor_id, min(occurred_at) FROM pixelex_events
          WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
            AND name = ANY($4) AND visitor_id IS NOT NULL
          GROUP BY visitor_id
          """,
          [@site, at(-60), at(600), ["px.pageview", "book_click"]]
        )

      refute p =~ ~r/Seq Scan on pixelex_events\b/,
             "the parent table must never be scanned directly:\n#{p}"
    end

    test "grouped reports always carry a limit" do
      # The contract, asserted rather than trusted: a caller cannot ask for
      # everything, and a LiveView cannot be handed a million rows.
      assert length(Traffic.top_pages(@site, range(-60, 600), limit: 3)) == 3
      assert length(Traffic.top_pages(@site, range(-60, 600))) <= 100
    end

    test "the reports a dashboard renders stay in single-digit milliseconds" do
      range = range(-60, 600)

      {micros, _} =
        :timer.tc(fn ->
          Traffic.summary(@site, range)
          Traffic.timeseries(@site, range)
          Traffic.top_pages(@site, range)
          Traffic.sources(@site, range)
          Traffic.devices(@site, range)
        end)

      assert micros < 500_000, "five reports took #{div(micros, 1000)}ms on 500 rows"
    end
  end
end
