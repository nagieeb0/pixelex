defmodule Pixelex.Query.Interactions do
  @moduledoc """
  What a visitor could act on, what they acted on, and how far they got.

  The browser tracker emits a closed set of library-owned events. Automatic
  capture never reads field values or page text: labels exist only when the
  host explicitly supplies `data-track-label`.
  """

  alias Pixelex.Query
  alias Pixelex.Query.Range

  @table "pixelex_events"

  @doc "The newest interactive-element inventory seen for each path."
  def inventory(site_id, %Range{} = range, opts \\ []) do
    """
    SELECT DISTINCT ON (pathname)
      pathname,
      COALESCE((props->>'interactive')::integer, 0),
      COALESCE((props->>'buttons')::integer, 0),
      COALESCE((props->>'links')::integer, 0),
      COALESCE(props->>'actions', ''),
      occurred_at
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
      AND name = 'px.inventory'
      AND COALESCE(props->>'interactive', '0') ~ '^\\d+$'
      AND COALESCE(props->>'buttons', '0') ~ '^\\d+$'
      AND COALESCE(props->>'links', '0') ~ '^\\d+$'
    ORDER BY pathname, occurred_at DESC
    LIMIT $4
    """
    |> Query.rows([site_id, range.from, range.to, Query.limit!(opts[:limit])])
    |> Enum.map(fn [path, interactive, buttons, links, actions, at] ->
      %{
        path: path,
        interactive: interactive,
        buttons: buttons,
        links: links,
        actions: actions,
        at: at
      }
    end)
  end

  @doc "Clicks grouped by semantic action and optional developer label."
  def clicks(site_id, %Range{} = range, opts \\ []) do
    """
    SELECT COALESCE(NULLIF(props->>'action', ''), 'interact') AS action,
           NULLIF(props->>'label', '') AS label,
           count(*) AS events,
           count(DISTINCT session_id) AS sessions,
           count(DISTINCT visitor_id) AS visitors
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
      AND name = 'px.click'
    GROUP BY action, label
    ORDER BY events DESC
    LIMIT $4
    """
    |> Query.rows([site_id, range.from, range.to, Query.limit!(opts[:limit])])
    |> Enum.map(fn [action, label, events, sessions, visitors] ->
      %{action: action, label: label, events: events, sessions: sessions, visitors: visitors}
    end)
  end

  @doc "Maximum scroll depth and engaged time reported in the range."
  def engagement(site_id, %Range{} = range) do
    [events, sessions, average_depth, maximum_depth, engaged_ms] =
      Query.one(
        """
        SELECT count(*), count(DISTINCT session_id),
               COALESCE(avg((props->>'d')::numeric), 0),
               COALESCE(max((props->>'d')::integer), 0),
               COALESCE(sum((props->>'ms')::bigint), 0)
        FROM #{@table}
        WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
          AND name = 'px.engagement'
          AND COALESCE(props->>'d', '0') ~ '^\\d+$'
          AND COALESCE(props->>'ms', '0') ~ '^\\d+$'
        """,
        [site_id, range.from, range.to]
      )

    %{
      events: events,
      sessions: sessions,
      average_depth: average_depth |> Decimal.to_float() |> Float.round(1),
      maximum_depth: maximum_depth,
      engaged_ms: integer(engaged_ms)
    }
  end

  @doc "Newest events, bounded for an operator-facing timeline."
  def timeline(site_id, %Range{} = range, opts \\ []) do
    """
    SELECT occurred_at, name, pathname, props
    FROM #{@table}
    WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
    ORDER BY occurred_at DESC
    LIMIT $4
    """
    |> Query.rows([site_id, range.from, range.to, Query.limit!(opts[:limit] || 50)])
    |> Enum.map(fn [at, name, path, props] ->
      %{at: at, name: name, path: path, props: props || %{}}
    end)
  end

  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value) when is_integer(value), do: value
end
