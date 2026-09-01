defmodule Pixelex.Query.Traffic do
  @moduledoc """
  Who came, from where, on what, and to which pages.

  Every function takes `site_id` and a `Pixelex.Query.Range` and returns plain
  maps. Every grouped query carries a `LIMIT`; every query is bounded by the
  range, so the planner prunes to the partitions it overlaps.

  ## `visitors` is a daily count

  Within a single day `count(DISTINCT visitor_id)` is exact. Over a longer
  window it is a **sum of dailies** and therefore an over-count of people,
  because the visitor hash rotates at midnight UTC. `summary/2` returns it as
  `:visitors_daily_sum` rather than `:visitors`, because a field called
  "unique visitors" that is not unique is worse than no field.
  """

  alias Pixelex.Query
  alias Pixelex.Query.Range

  @pageview "px.pageview"
  @table "pixelex_events"

  @doc """
  Headline numbers for the window.

      %{
        pageviews: 4_182,
        events: 5_006,
        sessions: 1_204,
        visitors_daily_sum: 1_103,
        bounce_rate: 0.42,
        views_per_session: 3.47
      }

  `bounce_rate` is the share of sessions with exactly one page view.
  """
  @spec summary(String.t(), Range.t()) :: map()
  def summary(site_id, %Range{} = range) do
    [pageviews, events, sessions, visitors, bounced] =
      Query.one(
        """
        WITH scoped AS (
          SELECT name, session_id, visitor_id, occurred_at
          FROM #{@table}
          WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
        ),
        per_session AS (
          SELECT session_id, count(*) FILTER (WHERE name = $4) AS views
          FROM scoped WHERE session_id IS NOT NULL GROUP BY session_id
        )
        SELECT
          (SELECT count(*) FROM scoped WHERE name = $4),
          (SELECT count(*) FROM scoped),
          (SELECT count(*) FROM per_session),
          (SELECT count(DISTINCT visitor_id) FROM scoped),
          (SELECT count(*) FROM per_session WHERE views <= 1)
        """,
        [site_id, range.from, range.to, @pageview]
      )

    %{
      pageviews: pageviews,
      events: events,
      sessions: sessions,
      visitors_daily_sum: visitors,
      bounce_rate: ratio(bounced, sessions),
      views_per_session: ratio(pageviews, sessions)
    }
  end

  @doc """
  Page views and sessions per time bucket, for a chart.

  The bucket is chosen from the window's length unless given, so a year never
  returns 8,760 hourly points to render across eight hundred pixels.
  """
  @spec timeseries(String.t(), Range.t(), keyword()) :: [map()]
  def timeseries(site_id, %Range{} = range, opts \\ []) do
    bucket = Query.validate_bucket!(opts[:bucket] || Query.bucket(range))

    # `bucket` is interpolated, not parameterised — date_trunc takes its unit as
    # SQL text. validate_bucket!/1 is the allowlist that makes that safe, and it
    # is the only interpolation anywhere in this module.
    """
    SELECT date_trunc('#{bucket}', occurred_at) AS at,
           count(*) FILTER (WHERE name = $4) AS pageviews,
           count(DISTINCT session_id) AS sessions,
           count(DISTINCT visitor_id) AS visitors
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
    GROUP BY at
    ORDER BY at
    """
    |> Query.rows([site_id, range.from, range.to, @pageview])
    |> Enum.map(fn [at, pageviews, sessions, visitors] ->
      %{at: at, pageviews: pageviews, sessions: sessions, visitors: visitors}
    end)
  end

  @doc "Most-viewed paths."
  @spec top_pages(String.t(), Range.t(), keyword()) :: [map()]
  def top_pages(site_id, %Range{} = range, opts \\ []) do
    grouped(site_id, range, "pathname", Query.limit!(opts[:limit]), name: @pageview)
  end

  @doc """
  Where visitors came from, by resolved source.

  Reads `attribution->'last'->>'source'`, so a Google ad shows as `google` and
  organic Google as `Google` — the click-id path and the referrer path resolve
  separately by design. Group by `medium/1` to collapse them.
  """
  @spec sources(String.t(), Range.t(), keyword()) :: [map()]
  def sources(site_id, %Range{} = range, opts \\ []) do
    grouped(site_id, range, "attribution->'last'->>'source'", Query.limit!(opts[:limit]))
  end

  @doc "Traffic by channel: `organic_search`, `paid_social`, `referral`, `none`, …"
  @spec mediums(String.t(), Range.t(), keyword()) :: [map()]
  def mediums(site_id, %Range{} = range, opts \\ []) do
    grouped(site_id, range, "attribution->'last'->>'medium'", Query.limit!(opts[:limit]))
  end

  @doc "Paid campaigns by name, with the click ids that carried them."
  @spec campaigns(String.t(), Range.t(), keyword()) :: [map()]
  def campaigns(site_id, %Range{} = range, opts \\ []) do
    """
    SELECT attribution->'last'->>'campaign' AS campaign,
           attribution->'last'->>'network' AS network,
           count(*) AS events,
           count(DISTINCT session_id) AS sessions,
           count(DISTINCT visitor_id) AS visitors
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
      AND attribution->'last'->>'campaign' IS NOT NULL
    GROUP BY campaign, network
    ORDER BY events DESC
    LIMIT $4
    """
    |> Query.rows([site_id, range.from, range.to, Query.limit!(opts[:limit])])
    |> Enum.map(fn [campaign, network, events, sessions, visitors] ->
      %{
        campaign: campaign,
        network: network,
        events: events,
        sessions: sessions,
        visitors: visitors
      }
    end)
  end

  @doc "Countries, by ISO-3166-1 alpha-2 code."
  @spec countries(String.t(), Range.t(), keyword()) :: [map()]
  def countries(site_id, range, opts \\ []),
    do: grouped(site_id, range, "country", Query.limit!(opts[:limit]))

  @doc "Browsers."
  @spec browsers(String.t(), Range.t(), keyword()) :: [map()]
  def browsers(site_id, range, opts \\ []),
    do: grouped(site_id, range, "browser", Query.limit!(opts[:limit]))

  @doc "Operating systems."
  @spec operating_systems(String.t(), Range.t(), keyword()) :: [map()]
  def operating_systems(site_id, range, opts \\ []),
    do: grouped(site_id, range, "os", Query.limit!(opts[:limit]))

  @doc "Device types: `desktop`, `smartphone`, `tablet`, …"
  @spec devices(String.t(), Range.t(), keyword()) :: [map()]
  def devices(site_id, range, opts \\ []),
    do: grouped(site_id, range, "device_type", Query.limit!(opts[:limit]))

  @doc "Custom events by name, page views excluded."
  @spec events(String.t(), Range.t(), keyword()) :: [map()]
  def events(site_id, %Range{} = range, opts \\ []) do
    """
    SELECT name, count(*) AS events,
           count(DISTINCT session_id) AS sessions,
           count(DISTINCT visitor_id) AS visitors
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3 AND name <> $4
    GROUP BY name
    ORDER BY events DESC
    LIMIT $5
    """
    |> Query.rows([site_id, range.from, range.to, @pageview, Query.limit!(opts[:limit])])
    |> Enum.map(fn [name, events, sessions, visitors] ->
      %{value: name, events: events, sessions: sessions, visitors: visitors}
    end)
  end

  # --- internals --------------------------------------------------------------

  # `expression` is always a literal from this module — a column name or a JSON
  # path written above. It is never derived from a caller's input, which is what
  # keeps interpolating it into SQL safe. Adding a public function that takes a
  # column name from outside would break that, so do not.
  defp grouped(site_id, %Range{} = range, expression, limit, filters \\ []) do
    {name_clause, params} =
      case filters[:name] do
        nil -> {"", [site_id, range.from, range.to, limit]}
        name -> {"AND name = $5", [site_id, range.from, range.to, limit, name]}
      end

    """
    SELECT #{expression} AS value,
           count(*) AS events,
           count(DISTINCT session_id) AS sessions,
           count(DISTINCT visitor_id) AS visitors
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
      AND #{expression} IS NOT NULL
      #{name_clause}
    GROUP BY value
    ORDER BY events DESC
    LIMIT $4
    """
    |> Query.rows(params)
    |> Enum.map(fn [value, events, sessions, visitors] ->
      %{value: value, events: events, sessions: sessions, visitors: visitors}
    end)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 4)
end
