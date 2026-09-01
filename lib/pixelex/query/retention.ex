defmodule Pixelex.Query.Retention do
  @moduledoc """
  Of the people who first appeared in week 0, how many came back in week 1,
  week 2, week 3.

      Pixelex.Query.Retention.cohorts("shop", range, bucket: "week")

      %{
        bucket: "week",
        cohorts: [
          %{cohort: ~U[2026-08-03 00:00:00Z], size: 412,
            periods: [%{period: 0, users: 412, rate: 1.0},
                      %{period: 1, users: 173, rate: 0.42},
                      %{period: 2, users: 98,  rate: 0.238}]},
          …
        ]
      }

  ## This works on `user_id`, and it has to

  `visitor_id` is a keyed hash under a salt that **rotates every UTC day**.
  Tomorrow the same person hashes to a different value — that is what makes
  pixelex cookieless, and it makes anonymous retention arithmetically
  impossible, not merely unimplemented. Retaining a stable identifier across
  days means putting one on the visitor's device, and putting one there is
  exactly what ePrivacy Article 5(3) governs.

  So this counts signed-in users, from `Pixelex.identify/3` onward. If nothing
  calls `identify/3`, every cohort is empty and that is the honest answer
  rather than a plausible-looking wrong one.

  ## Cohorts are scoped to the window

  A user's cohort is the bucket of their **first event inside the range**, not
  their first event ever. Someone who signed up last year and returned today
  appears in today's cohort. Widening the range fixes it and costs more; there
  is no third option that is both bounded and correct, and an unbounded scan of
  the events table is not an option at all.

  `:first_seen_from` moves just the first-seen lookback earlier while keeping
  the activity window narrow, which is the useful middle:

      cohorts("shop", last_30_days, first_seen_from: ninety_days_ago)
  """

  alias Pixelex.Query
  alias Pixelex.Query.Range

  @table "pixelex_events"

  @doc """
  Retention grid for signed-in users.

  ## Options

    * `:bucket` — `"day"`, `"week"` (default) or `"month"`
    * `:first_seen_from` — a `DateTime` to look further back for first-seen
    * `:event` — only count activity on this event name
    * `:limit` — maximum cohorts returned (default 26)
  """
  @spec cohorts(String.t(), Range.t(), keyword()) :: map()
  def cohorts(site_id, %Range{} = range, opts \\ []) do
    bucket = Query.validate_bucket!(opts[:bucket] || "week")
    first_from = opts[:first_seen_from] || range.from
    limit = Query.limit!(opts[:limit] || 26)

    {event_clause, params} =
      case opts[:event] do
        nil -> {"", [site_id, range.from, range.to, first_from]}
        event -> {"AND e.name = $5", [site_id, range.from, range.to, first_from, event]}
      end

    rows =
      Query.rows(
        """
        WITH first_seen AS (
          SELECT user_id, date_trunc('#{bucket}', min(occurred_at)) AS cohort
          FROM #{@table}
          WHERE site_id = $1 AND occurred_at >= $4 AND occurred_at < $3
            AND user_id IS NOT NULL
          GROUP BY user_id
        ),
        activity AS (
          SELECT DISTINCT f.cohort,
                          date_trunc('#{bucket}', e.occurred_at) AS period,
                          e.user_id
          FROM #{@table} e
          JOIN first_seen f ON f.user_id = e.user_id
          WHERE e.site_id = $1 AND e.occurred_at >= $2 AND e.occurred_at < $3
            AND e.user_id IS NOT NULL
            #{event_clause}
        )
        SELECT cohort, period, count(*) AS users
        FROM activity
        GROUP BY cohort, period
        ORDER BY cohort, period
        """,
        params
      )

    %{bucket: bucket, cohorts: shape(rows, bucket, limit)}
  end

  # --- shaping ----------------------------------------------------------------

  defp shape(rows, bucket, limit) do
    rows
    |> Enum.group_by(fn [cohort, _period, _users] -> cohort end)
    |> Enum.sort_by(fn {cohort, _} -> cohort end, {:desc, NaiveDateTime})
    |> Enum.take(limit)
    |> Enum.map(fn {cohort, cohort_rows} -> cohort_grid(cohort, cohort_rows, bucket) end)
    |> Enum.sort_by(& &1.cohort, {:asc, NaiveDateTime})
  end

  defp cohort_grid(cohort, rows, bucket) do
    size =
      Enum.find_value(rows, 0, fn [_c, period, users] ->
        if period == cohort, do: users
      end)

    periods =
      rows
      |> Enum.map(fn [_c, period, users] ->
        %{
          period: periods_between(cohort, period, bucket),
          users: users,
          rate: rate(users, size)
        }
      end)
      |> Enum.sort_by(& &1.period)

    %{cohort: cohort, size: size, periods: periods}
  end

  # date_trunc gives aligned bucket starts, so integer division of the gap is
  # exact for day and week. Months vary in length, so those are counted in
  # calendar months rather than divided.
  defp periods_between(cohort, period, "month") do
    (period.year - cohort.year) * 12 + (period.month - cohort.month)
  end

  defp periods_between(cohort, period, bucket) do
    seconds = NaiveDateTime.diff(period, cohort)

    case bucket do
      "day" -> div(seconds, 86_400)
      "week" -> div(seconds, 7 * 86_400)
      "hour" -> div(seconds, 3_600)
    end
  end

  defp rate(_users, 0), do: 0.0
  defp rate(users, size), do: Float.round(users / size, 4)
end
