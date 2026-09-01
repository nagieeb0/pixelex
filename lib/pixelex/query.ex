defmodule Pixelex.Query do
  @moduledoc """
  Reading the event log: traffic, funnels, retention, cohorts.

  Nothing on Hex does funnels, retention or cohorts. Plausible Community
  Edition withholds funnels as a paid feature. This is the part of pixelex that
  exists nowhere else.

  ## Every read is bounded, and the bound is not optional

  `from` and `to` are required arguments, not options with defaults, and every
  grouped query carries a `LIMIT`. On a table that takes every write in the
  system, an unbounded read is not a slow query — it is an outage waiting for
  the day the table gets big enough. Monthly partitioning means a bounded range
  touches only the partitions it overlaps and the planner prunes the rest, so
  the cost of a report is proportional to the window asked for rather than to
  the age of the site.

  ## Anonymous or identified — the distinction runs through everything

  `visitor_id` is a keyed hash under a salt that **rotates every UTC day**.
  Within a day it identifies a person; across days it cannot, by construction.
  That is what makes the scheme cookieless and it is not negotiable, so:

  | question | works on | across days? |
  |---|---|---|
  | page views, sessions, sources, devices | anonymous | yes — they are counts, not people |
  | unique visitors over a range | anonymous | **sum of dailies**, an over-count |
  | a funnel completed in one visit | `visitor_id` | no — same-day only |
  | a funnel completed over weeks | `user_id` | yes, for signed-in users |
  | retention, cohorts | `user_id` | yes, for signed-in users |

  Retention and cohorts therefore operate on `user_id` and say so. This is not
  a gap to be closed later: a durable cross-day identifier for anonymous
  visitors is a cookie, and putting one on the device is the thing that
  requires the banner pixelex exists to avoid.

  Call `Pixelex.identify/3` when a user signs in and the identified questions
  become answerable for them.
  """

  alias Pixelex.Config

  defmodule Range do
    @moduledoc "A closed-open time window, `from <= occurred_at < to`."
    @enforce_keys [:from, :to]
    defstruct [:from, :to]

    @type t :: %__MODULE__{from: DateTime.t(), to: DateTime.t()}
  end

  @doc """
  Build a range, or raise.

      Pixelex.Query.range(~U[2026-09-01 00:00:00Z], ~U[2026-10-01 00:00:00Z])
      Pixelex.Query.range(:last_30_days)
  """
  @spec range(DateTime.t() | atom(), DateTime.t() | nil) :: Range.t()
  def range(from, to \\ nil)

  def range(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(from, to) == :lt do
      %Range{from: from, to: to}
    else
      raise ArgumentError, "range `from` must be before `to`, got #{from} .. #{to}"
    end
  end

  def range(preset, nil) when is_atom(preset) do
    now = DateTime.utc_now()

    days =
      case preset do
        :today -> 1
        :last_7_days -> 7
        :last_30_days -> 30
        :last_90_days -> 90
        other -> raise ArgumentError, "unknown range preset #{inspect(other)}"
      end

    range(DateTime.add(now, -days, :day), now)
  end

  @doc "The window's length in days, rounded up. Used to pick a sensible bucket."
  @spec days(Range.t()) :: pos_integer()
  def days(%Range{from: from, to: to}), do: max(ceil(DateTime.diff(to, from) / 86_400), 1)

  @doc """
  A time bucket appropriate to the window: hourly up to two days, daily up to a
  quarter, weekly beyond, monthly past a year.

  Sized so a chart never asks for more points than a chart can show. A year of
  hourly buckets is 8,760 rows to render eight hundred pixels.
  """
  @spec bucket(Range.t()) :: String.t()
  def bucket(%Range{} = range) do
    case days(range) do
      d when d <= 2 -> "hour"
      d when d <= 92 -> "day"
      d when d <= 400 -> "week"
      _ -> "month"
    end
  end

  @doc false
  # Bucket names reach date_trunc as SQL text, so they can never come from a
  # caller. This is the allowlist that makes that true.
  @valid_buckets ~w(hour day week month)
  def validate_bucket!(bucket) when bucket in @valid_buckets, do: bucket

  def validate_bucket!(other),
    do:
      raise(
        ArgumentError,
        "bucket must be one of #{inspect(@valid_buckets)}, got #{inspect(other)}"
      )

  @doc false
  def sql!(query, params) do
    repo = Config.repo() || raise "Pixelex.Query needs `config :pixelex, repo: MyApp.Repo`"
    Ecto.Adapters.SQL.query!(repo, query, params)
  end

  @doc false
  def rows(query, params), do: sql!(query, params).rows

  @doc false
  def one(query, params) do
    case sql!(query, params).rows do
      [row] -> row
      _ -> nil
    end
  end

  @doc false
  # A guard against the one mistake that matters here. Callers pass a limit
  # through from a dashboard; a nil or an enormous one turns a report into a
  # table scan that returns a million rows to a LiveView.
  def limit!(nil), do: 100
  def limit!(n) when is_integer(n) and n > 0 and n <= 10_000, do: n

  def limit!(n) when is_integer(n) and n > 10_000, do: 10_000

  def limit!(other),
    do: raise(ArgumentError, "limit must be a positive integer, got #{inspect(other)}")
end
