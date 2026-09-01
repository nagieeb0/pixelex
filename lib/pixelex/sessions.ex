defmodule Pixelex.Sessions do
  @moduledoc """
  Sessions in ETS: thirty minutes of inactivity ends one.

  GoatCounter keeps sessions in memory and sweeps the stale ones, and gets 800
  hits/sec out of a $5 VPS doing it. This is that, in BEAM terms. A session is
  derived state — it can be rebuilt from the event log — so paying a database
  round-trip per event to store it would be paying for durability nobody needs.

  ## The midnight handover

  `resolve/3` looks the visitor up under today's salt first, then under
  yesterday's. A hit on yesterday's id **moves** the session to today's id and
  keeps going. Without that second lookup every session open at 00:00 UTC ends
  and a new one begins, so a site's session count spikes every night, average
  session duration collapses, and nothing anywhere reports an error.

  That is the whole reason `Pixelex.Identity.visitor/3` returns two ids.

  ## What is kept

  `{visitor_id, session_id, started_at_ms, last_seen_ms, events}` and nothing
  else — no IP, no user agent, no path. The table is bounded by the sweeper,
  which runs every minute and deletes anything past the timeout.
  """
  use GenServer
  require Logger

  alias Pixelex.{Config, Event, Identity}

  @table :pixelex_sessions
  @sweep_ms 60_000

  @type resolution :: %{
          visitor_id: String.t(),
          session_id: String.t(),
          new_session?: boolean(),
          event_index: non_neg_integer(),
          attribution: map()
        }

  # --- public ---------------------------------------------------------------

  @doc """
  Resolve a visitor to a session, starting or continuing one as needed.

  Returns the visitor id under **today's** salt, so callers always store the
  current-day identifier even when the session was found under yesterday's.

  `touch` is folded into the session's stored attribution, giving every event
  in the session the same first touch and a last touch that updates.

  ## The ceiling on first touch

  First touch is **session-scoped**, and that is a consequence of being
  cookieless rather than an oversight. Attributing a conversion to an ad clicked
  three weeks earlier requires a durable identifier on the visitor's device, and
  putting one there is exactly what ePrivacy Article 5(3) governs — the rule
  that makes a banner necessary. A library cannot promise "no cookie banner" and
  "thirty-day first-touch attribution" at the same time; anything claiming both
  is doing the second one unlawfully in the EEA.

  The opt-in exists for hosts that have consent: with device-scoped first touch
  the JS tracker persists the first touch locally and sends it, and this becomes
  a true multi-visit first touch. It is off by default.
  """
  @spec resolve(String.t(), String.t() | nil, String.t() | nil, struct() | nil) :: resolution()
  def resolve(site_id, user_agent, ip, touch \\ nil) do
    %{id: id, previous_id: previous_id} = Identity.visitor(site_id, user_agent, ip)
    now = now_ms()
    timeout = Config.session_timeout_ms()

    case lookup(id, now, timeout) do
      {:ok, session} ->
        continue(session, now, touch)

      :miss ->
        case previous_id && lookup(previous_id, now, timeout) do
          {:ok, session} ->
            # Same human, new salt. Move the session across rather than
            # starting a second one for them.
            :ets.delete(@table, previous_id)
            session |> put_elem(0, id) |> continue(now, touch)

          _ ->
            start(id, now, touch)
        end
    end
  end

  @doc "How many sessions are currently held. Observability and tests."
  @spec active() :: non_neg_integer()
  def active do
    case :ets.info(@table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc "Drop every session. Tests only."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Delete sessions idle past the timeout. Runs on a timer; exposed for tests."
  @spec sweep() :: non_neg_integer()
  def sweep do
    ensure_table()
    cutoff = now_ms() - Config.session_timeout_ms()

    :ets.select_delete(@table, [
      {{:_, :_, :_, :"$1", :_, :_}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  # --- server ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    ensure_table()
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep() do
      0 -> :ok
      n -> Logger.debug("Pixelex swept #{n} idle session(s)")
    end

    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ------------------------------------------------------------

  defp lookup(nil, _now, _timeout), do: :miss

  defp lookup(id, now, timeout) do
    case :ets.lookup(@table, id) do
      [{_id, _sid, _started, last_seen, _n, _meta} = session] when now - last_seen < timeout ->
        {:ok, session}

      [{_id, _, _, _, _, _}] ->
        # Idle past the timeout. Delete rather than leave it for the sweeper —
        # otherwise the next event resurrects a session that already ended.
        :ets.delete(@table, id)
        :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      ensure_table()
      :miss
  end

  defp start(id, now, touch) do
    session_id = Event.uuid7()
    meta = %{attribution: merge_touch(nil, touch), last_pageview: nil}
    :ets.insert(@table, {id, session_id, now, now, 1, meta})

    %{
      visitor_id: id,
      session_id: session_id,
      new_session?: true,
      event_index: 0,
      attribution: meta.attribution
    }
  end

  defp continue({id, session_id, started, _last_seen, count, meta}, now, touch) do
    meta = %{meta | attribution: merge_touch(meta.attribution, touch)}
    :ets.insert(@table, {id, session_id, started, now, count + 1, meta})

    %{
      visitor_id: id,
      session_id: session_id,
      new_session?: false,
      event_index: count,
      attribution: meta.attribution
    }
  end

  defp merge_touch(stored, nil), do: stored || %{}
  defp merge_touch(stored, touch), do: Pixelex.Attribution.merge(stored, touch)

  @doc """
  Is this page view a repeat of the one just recorded for this session?

  Returns `true` — and records the path — when the session has NOT seen this
  path in the last `window_ms`, so the caller records it.

  ## What this is for

  A Phoenix LiveView renders every page twice: once as plain HTML over HTTP
  (the dead render), then again when the WebSocket connects. `mount/3` and
  `handle_params/3` both run twice. Count both and every human is two visitors;
  count only the connected one and crawlers, no-JS clients and anyone whose
  socket never opens disappear.

  Neither is acceptable, and no flag on the socket distinguishes the two cases
  reliably — a `push_navigate` into a LiveView also mounts exactly once,
  connected, with no dead render before it. So the honest test is behavioural:
  the same session asking for the same path twice inside a few seconds is one
  page view. A genuine reload is slower than that; a real navigation changes
  the path.
  """
  @spec first_view?(String.t(), String.t() | nil, pos_integer()) :: boolean()
  def first_view?(visitor_id, pathname, window_ms \\ 5_000) do
    ensure_table()
    now = now_ms()

    case :ets.lookup(@table, visitor_id) do
      [{id, sid, started, last_seen, count, %{last_pageview: {^pathname, at}} = meta}]
      when now - at < window_ms ->
        _ = {id, sid, started, last_seen, count, meta}
        false

      [{id, sid, started, last_seen, count, meta}] ->
        :ets.insert(
          @table,
          {id, sid, started, last_seen, count, %{meta | last_pageview: {pathname, now}}}
        )

        true

      [] ->
        true
    end
  rescue
    ArgumentError -> true
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp now_ms, do: System.system_time(:millisecond)
end
