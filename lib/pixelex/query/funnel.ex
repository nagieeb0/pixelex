defmodule Pixelex.Query.Funnel do
  @moduledoc """
  How many people made it from the first step to the last, and where the rest
  stopped.

  Nothing else on Hex does this. Plausible Community Edition withholds funnels
  as a paid feature, so in Elixir today the only way to answer this question is
  to ship your data to PostHog.

      Pixelex.Query.Funnel.run("shop", range, [
        "px.pageview", "view_doctor", "book_click", "booking_completed"
      ])

      %{
        steps: [
          %{name: "px.pageview",        count: 4182, rate: 1.0,    step_rate: 1.0,   dropped: 3011},
          %{name: "view_doctor",        count: 1171, rate: 0.28,   step_rate: 0.28,  dropped: 894},
          %{name: "book_click",         count: 277,  rate: 0.066,  step_rate: 0.237, dropped: 129},
          %{name: "booking_completed",  count: 148,  rate: 0.035,  step_rate: 0.534, dropped: 0}
        ],
        conversion_rate: 0.035,
        subject: :visitor
      }

  `rate` is against the first step; `step_rate` is against the step before —
  the second is what tells you which step is broken.

  ## Order is enforced, not assumed

  Each step is built from the one before it in its own CTE, so step 3 only
  counts events that happened **at or after** that subject's step 2. The
  shortcut most implementations take —
  `min(occurred_at) FILTER (WHERE name = step_n)` in a single pass — silently
  drops anyone who did step 3 before step 2 and again after it, and silently
  counts nobody whose steps interleave. This costs one CTE per step and is
  correct.

  ## Which subject: `:visitor` or `:user`

  `visitor_id` is a hash under a salt that rotates every UTC day, so a funnel
  keyed on it **cannot span midnight**. That is right for a checkout and wrong
  for an onboarding funnel measured over a week.

      run(site, range, steps, subject: :user)

  keys on `user_id` instead, which only exists after `Pixelex.identify/3`. Pick
  `:visitor` for a single-visit funnel and `:user` for anything longer, and be
  aware that `:user` counts only signed-in people.

  ## Conversion window

      run(site, range, steps, within: {2, "hours"})

  bounds how long a subject has to get from one step to the next. Without it,
  a visitor who bounced in March and converted in May counts as one funnel.
  """

  alias Pixelex.Query
  alias Pixelex.Query.Range

  @table "pixelex_events"
  @max_steps 10

  @type subject :: :visitor | :user

  @doc """
  Run an ordered funnel.

  ## Options

    * `:subject` — `:visitor` (default) or `:user`
    * `:within` — `{amount, unit}`, e.g. `{30, "minutes"}`. Units are
      `minutes`, `hours` or `days`.
  """
  @spec run(String.t(), Range.t(), [String.t()], keyword()) :: map()
  def run(site_id, %Range{} = range, steps, opts \\ []) when is_list(steps) do
    steps = validate_steps!(steps)
    subject = subject_column!(opts[:subject] || :visitor)
    within = validate_within!(opts[:within])

    counts =
      Query.one(
        sql(steps, subject, within),
        [site_id, range.from, range.to, steps] ++ steps
      )

    %{
      steps: shape(steps, counts),
      conversion_rate: rate(List.last(counts), List.first(counts)),
      subject: opts[:subject] || :visitor
    }
  end

  # --- sql --------------------------------------------------------------------

  defp sql(steps, subject, within) do
    indices = Enum.with_index(steps)

    ctes =
      indices
      |> Enum.map(fn {_step, i} -> cte(i, within) end)
      |> Enum.join(",\n")

    selects =
      indices
      |> Enum.map(fn {_step, i} -> "(SELECT count(*) FROM step_#{i})" end)
      |> Enum.join(",\n  ")

    """
    WITH scoped AS (
      SELECT #{subject} AS subject, name, occurred_at
      FROM #{@table}
      WHERE site_id = $1
        AND occurred_at >= $2
        AND occurred_at < $3
        AND name = ANY($4)
        AND #{subject} IS NOT NULL
    ),
    #{ctes}
    SELECT
      #{selects}
    """
  end

  # Step 0 is everyone who did the first thing. Every later step joins back to
  # the previous one and takes only events at or after it, which is what makes
  # this an ordered funnel rather than a set intersection.
  defp cte(0, _within) do
    """
    step_0 AS (
      SELECT subject, min(occurred_at) AS at
      FROM scoped WHERE name = $5 GROUP BY subject
    )
    """
  end

  defp cte(i, within) do
    window =
      case within do
        nil -> ""
        {amount, unit} -> "AND e.occurred_at <= p.at + interval '#{amount} #{unit}'"
      end

    """
    step_#{i} AS (
      SELECT p.subject, min(e.occurred_at) AS at
      FROM step_#{i - 1} p
      JOIN scoped e ON e.subject = p.subject AND e.name = $#{i + 5} AND e.occurred_at >= p.at
        #{window}
      GROUP BY p.subject
    )
    """
  end

  # --- validation -------------------------------------------------------------

  defp validate_steps!(steps) do
    cond do
      steps == [] ->
        raise ArgumentError, "a funnel needs at least one step"

      length(steps) > @max_steps ->
        raise ArgumentError, "a funnel is capped at #{@max_steps} steps; got #{length(steps)}"

      not Enum.all?(steps, &(is_binary(&1) and &1 != "")) ->
        raise ArgumentError, "funnel steps must be non-empty event names, got #{inspect(steps)}"

      true ->
        steps
    end
  end

  defp subject_column!(:visitor), do: "visitor_id"
  defp subject_column!(:user), do: "user_id"

  defp subject_column!(other),
    do: raise(ArgumentError, "subject must be :visitor or :user, got #{inspect(other)}")

  # `within` is interpolated into an interval literal, so it is validated to a
  # positive integer and one of three literal unit strings. Nothing a caller
  # writes reaches the query as text.
  defp validate_within!(nil), do: nil

  defp validate_within!({amount, unit})
       when is_integer(amount) and amount > 0 and unit in ~w(minutes hours days) do
    {amount, unit}
  end

  defp validate_within!(other) do
    raise ArgumentError,
          "within must be {positive_integer, \"minutes\"|\"hours\"|\"days\"}, got #{inspect(other)}"
  end

  # --- shaping ----------------------------------------------------------------

  defp shape(steps, counts) do
    first = List.first(counts)

    steps
    |> Enum.zip(counts)
    |> Enum.with_index()
    |> Enum.map(fn {{name, count}, index} ->
      previous = if index == 0, do: count, else: Enum.at(counts, index - 1)
      next = Enum.at(counts, index + 1)

      %{
        name: name,
        count: count,
        rate: rate(count, first),
        step_rate: rate(count, previous),
        dropped: if(next, do: previous_drop(count, next), else: 0)
      }
    end)
  end

  defp previous_drop(count, next), do: max(count - next, 0)

  defp rate(_numerator, denominator) when denominator in [0, nil], do: 0.0
  defp rate(nil, _denominator), do: 0.0
  defp rate(numerator, denominator), do: Float.round(numerator / denominator, 4)
end
