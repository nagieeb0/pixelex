defmodule Pixelex.Config do
  @moduledoc """
  Every knob, with its default and the reason the default is what it is.

  Read through functions rather than `Application.get_env/3` at call sites, so
  there is one place to look when a number needs explaining and one place to
  change when it needs tuning.
  """

  @doc "The host application's Ecto repo. Required by `Pixelex.Store.Postgres`."
  def repo, do: get(:repo)

  @doc "Storage adapter. See `Pixelex.Store`."
  def store, do: get(:store, Pixelex.Store.Postgres)

  @doc """
  Flush the ingest buffer once this many bytes have accumulated.

  100KB is Plausible's threshold. Large enough that a bulk insert amortises the
  round-trip, small enough that a crash loses a fraction of a second of events.
  """
  def flush_bytes, do: get(:flush_bytes, 100_000)

  @doc "Flush the ingest buffer at least this often, whatever the byte count."
  def flush_ms, do: get(:flush_ms, 5_000)

  @doc """
  Drop events once the buffer holds this many.

  Analytics must never apply backpressure to a request. When the store is down
  or slow the correct behaviour is to lose events, loudly, rather than to grow
  a queue until the node dies with the rest of the application inside it.
  """
  def max_buffer, do: get(:max_buffer, 50_000)

  @doc "Inactivity after which a session is considered over. 30 minutes is the industry convention."
  def session_timeout_ms, do: get(:session_timeout_ms, 30 * 60 * 1_000)

  @doc """
  How often the salt ETS cache reloads from the store.

  Not the rotation period — this only converges the cache across nodes after
  whichever node ran the rotation wrote the new salt.
  """
  def salt_refresh_ms, do: get(:salt_refresh_ms, 90_000)

  @doc """
  `:repo` persists salts (survives restart, safest operationally) or `:memory`
  keeps them only in ETS (Ackee's posture — a database backup can never be
  replayed to reconstruct browsing history, at the cost of severing every open
  session on restart).
  """
  def salt_persistence, do: get(:salt_persistence, :repo)

  @doc "Delete salts older than this. Two rotations' worth, so `previous` is always available."
  def salt_ttl_hours, do: get(:salt_ttl_hours, 48)

  @doc "Days of raw events kept before the partition is dropped. Rollups are kept indefinitely."
  def retention_days, do: get(:retention_days, 90)

  @doc """
  Honour the `Sec-GPC: 1` request header.

  Defaults on. GPC is a legally binding opt-out under CCPA/CPRA and a growing
  set of US state laws, unlike DNT which never had legal force. Checked
  server-side because the client cannot be trusted to check it and an
  ad-blocker may have stripped the script that would have.
  """
  def honor_gpc?, do: get(:honor_gpc, true)

  @doc "Honour `DNT: 1`. Courtesy only — DNT has no legal force and Safari removed it."
  def honor_dnt?, do: get(:honor_dnt, false)

  @doc """
  Window in which a repeat page view for the same session and path is treated
  as the same view.

  Sized for the LiveView dead-render / connected-render pair, which arrive
  within a few hundred milliseconds of each other. A genuine reload takes
  longer; a real navigation changes the path.
  """
  def pageview_dedupe_ms, do: get(:pageview_dedupe_ms, 5_000)

  @doc "Ingest endpoint mount point. Configurable because a fixed path is what filter lists block."
  def ingest_path, do: get(:ingest_path, "/px")

  @doc "Ingest rate limit: `{max_events, window_ms}` per IP. Far above a human, far below a script."
  def rate_limit, do: get(:rate_limit, {120, 60_000})

  @doc """
  Today, in UTC.

  Indirected through config for one reason: salt rotation happens at a day
  boundary, and the behaviour at that boundary — a session surviving it — is
  the single most consequential thing in this library and the easiest to break
  without noticing. Code that cannot be tested at midnight is code that is
  wrong at midnight. Tests set `:clock` to a zero-arity function; nothing else
  ever should.
  """
  @spec today() :: Date.t()
  def today do
    case get(:clock) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Date.utc_today()
    end
  end

  defp get(key, default \\ nil), do: Application.get_env(:pixelex, key, default)
end
