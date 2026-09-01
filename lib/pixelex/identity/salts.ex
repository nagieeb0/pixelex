defmodule Pixelex.Identity.Salts do
  @moduledoc """
  Today's hashing salt and yesterday's, cached in ETS.

  A visitor is identified by a keyed hash of their user agent and IP. The key
  is a random salt that changes every UTC day and is deleted shortly after, so
  the identifier is unlinkable across days and cannot be recomputed later even
  with the raw inputs. That is what makes the scheme pseudonymous while it
  lives and anonymous once the salt is gone — and it is why pixelex needs no
  cookie, and therefore no banner.

  ## Rotation without a scheduler

  The salts table is keyed by UTC date. Rotation is
  `INSERT ... ON CONFLICT DO NOTHING` for today: the first node to notice the
  new day writes a salt, every other node reads it. No cron job to forget, no
  leader election, and no window in which two nodes hash the same visitor
  differently.

  ## `previous` is not an optimisation

  It is the whole reason this module has state at all. At 00:00 UTC the salt
  changes, so every visitor's hash changes, so every open session looks like a
  brand new person. `Pixelex.Identity` computes the id under **both** salts and
  the session lookup tries both — which is the only thing standing between this
  design and data that quietly corrupts itself one night at a time. Plausible
  does the same; it is the subtlest part of the scheme and the easiest to omit
  without noticing, because nothing fails, the numbers just get worse.

  ## Refresh, rotation and cleanup are three different clocks

    * **refresh** (`salt_refresh_ms`, 90s) — reload ETS from the store. Only
      converges nodes after one of them rotated. Does not create anything.
    * **rotation** (daily, 00:00 UTC) — implied by the date key, above.
    * **cleanup** (`salt_ttl_hours`, 48h) — delete salts older than two
      rotations, so `previous` is always still there.

  ## `:memory` mode

  With `salt_persistence: :memory` nothing is written to the database. A
  backup can then never be replayed to reconstruct browsing history, which is
  the strictest posture available (Ackee's). The cost is that a restart severs
  every open session, and separate nodes disagree about who a visitor is.
  """
  use GenServer
  require Logger

  alias Pixelex.Config

  @table :pixelex_salts_cache
  @salt_bytes 32

  # --- public ---------------------------------------------------------------

  @doc """
  `%{current: binary, previous: binary | nil}`.

  Reads straight from ETS — no GenServer call, because this runs on the path of
  every single event and a serialised lookup there would be the bottleneck of
  the whole system.
  """
  @spec get() :: %{current: binary(), previous: binary() | nil}
  def get do
    case :ets.lookup(@table, :salts) do
      [{:salts, salts}] -> salts
      [] -> GenServer.call(__MODULE__, :refresh_now)
    end
  rescue
    ArgumentError -> GenServer.call(__MODULE__, :refresh_now)
  end

  @doc "Force a reload. Tests, and anything that just rotated deliberately."
  @spec refresh() :: %{current: binary(), previous: binary() | nil}
  def refresh, do: GenServer.call(__MODULE__, :refresh_now)

  @doc "Delete salts older than `salt_ttl_hours`. Safe to call from a cron."
  @spec cleanup() :: :ok
  def cleanup, do: GenServer.call(__MODULE__, :cleanup)

  # --- server ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{memory: %{}}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    {:noreply, load(state)}
  end

  @impl true
  def handle_call(:refresh_now, _from, state) do
    state = load(state)
    {:reply, cached(), state}
  end

  def handle_call(:cleanup, _from, state) do
    if Config.salt_persistence() == :repo do
      cutoff = Date.add(Config.today(), -ttl_days())
      sql!("DELETE FROM pixelex_salts WHERE day < $1", [cutoff])
    end

    {:reply, :ok, prune_memory(state)}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, load(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ------------------------------------------------------------

  defp load(state) do
    today = Config.today()
    yesterday = Date.add(today, -1)

    state =
      case Config.salt_persistence() do
        :repo -> load_from_repo(state, today, yesterday)
        :memory -> load_from_memory(state, today, yesterday)
      end

    schedule_refresh()
    state
  end

  defp load_from_repo(state, today, yesterday) do
    salts =
      try do
        ensure_day(today)

        %{
          current: fetch_day(today) || generate(),
          previous: fetch_day(yesterday)
        }
      rescue
        e ->
          # A database blip must not stop ingestion. Keep whatever is cached;
          # if nothing is, run on an ephemeral salt until the store is back —
          # a day of unlinkable ids beats an outage.
          Logger.warning("Pixelex salt load failed, using cached/ephemeral: #{inspect(e)}")
          cached() || %{current: generate(), previous: nil}
      end

    put(salts)
    state
  end

  defp load_from_memory(state, today, yesterday) do
    memory = Map.put_new_lazy(state.memory, today, &generate/0)
    put(%{current: memory[today], previous: memory[yesterday]})
    %{state | memory: memory}
  end

  defp ensure_day(day) do
    sql!(
      "INSERT INTO pixelex_salts (day, salt, inserted_at) VALUES ($1, $2, $3) " <>
        "ON CONFLICT (day) DO NOTHING",
      [day, generate(), DateTime.utc_now()]
    )
  end

  defp fetch_day(day) do
    case sql!("SELECT salt FROM pixelex_salts WHERE day = $1", [day]) do
      %{rows: [[salt]]} -> salt
      _ -> nil
    end
  end

  defp prune_memory(state) do
    keep = for d <- 0..ttl_days(), do: Date.add(Config.today(), -d)
    %{state | memory: Map.take(state.memory, keep)}
  end

  defp ttl_days, do: max(div(Config.salt_ttl_hours(), 24), 1)

  defp generate, do: :crypto.strong_rand_bytes(@salt_bytes)

  defp put(salts), do: :ets.insert(@table, {:salts, salts})

  defp cached do
    case :ets.lookup(@table, :salts) do
      [{:salts, salts}] -> salts
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, Config.salt_refresh_ms())

  defp sql!(query, params) do
    repo = Config.repo() || raise "Pixelex needs `config :pixelex, repo: MyApp.Repo`"
    Ecto.Adapters.SQL.query!(repo, query, params)
  end
end
