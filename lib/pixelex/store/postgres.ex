defmodule Pixelex.Store.Postgres do
  @moduledoc """
  The real store: the host application's own Postgres, and nothing else.

  ## No extensions

  Not TimescaleDB, not `hll`, not Citus. Verified across the hosts Phoenix apps
  actually run on: Neon ships TimescaleDB's Apache edition only, so continuous
  aggregates — the whole reason to want it — are absent; Supabase deprecated
  TimescaleDB at PG 17 over the licence and does not list `hll`; Fly MPG's
  extension set is the stock PG distribution. A library that needs an extension
  is a library most people cannot install, so this is plain SQL:

    * **monthly range partitions** on `occurred_at`
    * **rollups** written with `INSERT … ON CONFLICT DO UPDATE`, not
      `REFRESH MATERIALIZED VIEW`, which is a full recompute every time
    * **retention** by `DROP TABLE` on an expired partition — O(1), no vacuum
      storm, unlike `DELETE FROM … WHERE occurred_at < …`

  ## Bounds

  Every write is one `INSERT` of a whole batch. Reads live in `Pixelex.Query`
  and are date-bounded by construction; the partition key means a bounded range
  touches only the partitions it overlaps, and the planner prunes the rest.

  ## Idempotency

  `ON CONFLICT DO NOTHING` against the `(id, occurred_at)` primary key. A
  replayed batch collides instead of duplicating, which is what makes the
  ingest buffer safe to retry.
  """
  @behaviour Pixelex.Store

  import Ecto.Query

  alias Pixelex.{Config, Event}

  @table "pixelex_events"

  @impl true
  def insert_events(events) do
    rows = Enum.map(events, &to_row/1)

    case repo().insert_all(@table, rows, on_conflict: :nothing) do
      {n, _} -> {:ok, n}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def setup, do: {:error, :use_a_migration}

  @doc "The events table name, for hand-written queries and migrations."
  def table, do: @table

  @doc """
  Rows in a bounded window. The `from`/`to` bounds are not optional — an
  unbounded scan of this table is the one query that must never exist.
  """
  @spec events(String.t(), DateTime.t(), DateTime.t(), keyword()) :: Ecto.Query.t()
  def events(site_id, %DateTime{} = from, %DateTime{} = to, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)

    from(e in @table,
      where: e.site_id == ^site_id and e.occurred_at >= ^from and e.occurred_at < ^to,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
  end

  defp to_row(%Event{} = e) do
    [
      id: cast_uuid(e.id),
      v: e.v,
      site_id: e.site_id,
      name: e.name,
      occurred_at: truncate_us(e.timestamp),
      client_ts: truncate_us(e.client_ts),
      visitor_id: e.visitor_id,
      session_id: e.session_id,
      user_id: e.user_id,
      url: e.url,
      pathname: e.pathname,
      hostname: e.hostname,
      referrer: e.referrer,
      attribution: e.attribution,
      country: e.country,
      region: e.region,
      city: e.city,
      browser: e.browser,
      os: e.os,
      device_type: e.device_type,
      render: e.render && Atom.to_string(e.render),
      props: e.props
    ]
  end

  # Ecto.UUID.dump/1 gives the 16-byte binary the driver wants. A malformed id
  # cannot happen — Event.new/1 generates it — but insert_all raises on a bad
  # value and would fail the whole batch for one row, so fail closed to a fresh
  # id rather than take the surrounding 5,000 events down with it.
  defp cast_uuid(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> Ecto.UUID.dump!(Event.uuid7())
    end
  end

  defp truncate_us(nil), do: nil
  defp truncate_us(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp repo do
    Config.repo() ||
      raise """
      Pixelex.Store.Postgres needs a repo:

          config :pixelex, repo: MyApp.Repo
      """
  end
end
