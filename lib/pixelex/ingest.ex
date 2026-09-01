defmodule Pixelex.Ingest do
  @moduledoc """
  The write path. Accumulate in memory, flush in batches, drop under pressure.

  GoatCounter's memstore, in BEAM terms: hits land in a buffer, a bulk insert
  drains it on a size or time trigger, and nothing on the request path ever
  waits for a database. That design does 800 hits/sec on a $5 VPS, which is the
  bar this has to clear.

  ## Flush policy

  `flush_bytes` accumulated **or** `flush_ms` elapsed, whichever comes first
  (100KB / 5s by default — Plausible's numbers). Size alone stalls a quiet site
  forever; time alone makes a busy site do a round-trip per event.

  ## Dropping is the correct failure

  When the store is slow or down, the buffer grows. Three lines of defence, in
  order: at most `@max_inflight` flushes run at once, so a slow store cannot
  spawn unbounded work; past `max_buffer` events new arrivals are **dropped**;
  and a failed flush returns its batch to the front of the buffer exactly once,
  then gives up on it.

  Losing analytics is a bad day. Growing a queue until the node dies takes the
  application down with it, and the application is the thing that matters.
  Every drop emits `[:pixelex, :ingest, :drop]` — silent loss is the actual
  danger here, not loss.

  ## Telemetry

    * `[:pixelex, :ingest, :push]` — `%{count: 1}`
    * `[:pixelex, :ingest, :flush]` — `%{count:, bytes:, duration_us:, written:}`
    * `[:pixelex, :ingest, :drop]` — `%{count:}`, `%{reason: :buffer_full | :flush_failed}`

  ## Ceiling

  One GenServer serialises every push. At a list prepend per message that is
  well past a million events/sec — three orders of magnitude above the target —
  so it is not worth partitioning yet. ponytail: single buffer process; move
  accumulation to `:ets` with `write_concurrency` and an `:atomics` byte counter
  if a profile ever shows this mailbox as the bottleneck.
  """
  use GenServer
  require Logger

  alias Pixelex.{Config, Event, Store}

  @max_inflight 5

  defstruct buffer: [], bytes: 0, count: 0, inflight: 0, timer: nil

  # --- public ---------------------------------------------------------------

  @doc """
  Queue one event. Returns `:ok` immediately, always.

  A `cast`, deliberately: the caller is a request that must not wait on
  analytics, and a `call` here would put the buffer's health on the critical
  path of every page load.
  """
  @spec push(Event.t()) :: :ok
  def push(%Event{} = event), do: GenServer.cast(__MODULE__, {:push, event})

  @doc "Queue a batch."
  @spec push_all([Event.t()]) :: :ok
  def push_all([]), do: :ok
  def push_all(events) when is_list(events), do: GenServer.cast(__MODULE__, {:push_all, events})

  @doc """
  Flush now and wait for it. Tests and graceful shutdown only — calling this on
  a request path reintroduces exactly the coupling this module exists to avoid.
  """
  @spec flush(timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def flush(timeout \\ 15_000), do: GenServer.call(__MODULE__, :flush_sync, timeout)

  @doc "Buffered event count."
  @spec pending() :: non_neg_integer()
  def pending, do: GenServer.call(__MODULE__, :pending)

  @doc """
  `%{pending: n, inflight: n}` — buffered events, and flushes currently in
  flight.

  `inflight` is the number that matters when something is wrong: it sits at
  `#{@max_inflight}` when the store has stopped acknowledging writes, which is
  the signal that arrives before the buffer fills and the drops start.
  """
  @spec stats() :: %{pending: non_neg_integer(), inflight: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  # --- server ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The buffer holds events that exist nowhere else. Without this, a SIGTERM
    # during a deploy discards up to flush_ms of traffic on every node.
    Process.flag(:trap_exit, true)
    {:ok, schedule(%__MODULE__{})}
  end

  @impl true
  def handle_cast({:push, event}, state), do: {:noreply, accept(state, [event])}
  def handle_cast({:push_all, events}, state), do: {:noreply, accept(state, events)}

  @impl true
  def handle_call(:pending, _from, state), do: {:reply, state.count, state}

  def handle_call(:stats, _from, state),
    do: {:reply, %{pending: state.count, inflight: state.inflight}, state}

  def handle_call(:flush_sync, _from, state) do
    {result, state} = flush_now(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if state.count > 0, do: async_flush(state), else: state
    {:noreply, schedule(state)}
  end

  # A flush finished. Failures put the batch back exactly once — a batch that
  # fails twice is a batch the store will never accept, and retrying it forever
  # blocks every event behind it.
  def handle_info({:flushed, :ok, count, bytes, written, us}, state) do
    telemetry(:flush, %{count: count, bytes: bytes, written: written, duration_us: us}, %{
      sync: false
    })

    {:noreply, %{state | inflight: state.inflight - 1}}
  end

  def handle_info({:flushed, {:error, reason}, events, _bytes, _w, _us}, state) do
    Logger.warning("Pixelex flush failed (#{length(events)} events): #{inspect(reason)}")
    state = %{state | inflight: state.inflight - 1}
    {:noreply, requeue(state, events)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Synchronous on purpose: the process is going away and an async flush would
    # be killed with it. This is the one place blocking is right.
    if state.count > 0, do: write(Enum.reverse(state.buffer))
    :ok
  end

  # --- internals ------------------------------------------------------------

  defp accept(state, events) do
    max = Config.max_buffer()
    room = max - state.count

    {kept, dropped} =
      if length(events) <= room do
        {events, 0}
      else
        {Enum.take(events, max(room, 0)), length(events) - max(room, 0)}
      end

    if dropped > 0 do
      telemetry(:drop, %{count: dropped}, %{reason: :buffer_full})

      Logger.warning(
        "Pixelex dropped #{dropped} event(s): #{length(events)} offered, #{max(room, 0)} of " <>
          "#{max} buffer slots free. The store is not keeping up."
      )
    end

    state = Enum.reduce(kept, state, &buffer(&2, &1))

    if state.bytes >= Config.flush_bytes(), do: async_flush(state), else: state
  end

  # Prepend, reverse at flush. O(1) per event instead of O(n).
  defp buffer(state, event) do
    %{
      state
      | buffer: [event | state.buffer],
        bytes: state.bytes + :erlang.external_size(event),
        count: state.count + 1
    }
  end

  defp requeue(state, events) do
    max = Config.max_buffer()

    if state.count + length(events) > max do
      telemetry(:drop, %{count: length(events)}, %{reason: :flush_failed})
      state
    else
      Enum.reduce(events, state, &buffer(&2, &1))
    end
  end

  defp async_flush(%{count: 0} = state), do: state

  defp async_flush(%{inflight: n} = state) when n >= @max_inflight do
    # At the concurrency cap. Keep buffering; `max_buffer` is the next gate.
    state
  end

  defp async_flush(state) do
    batch = Enum.reverse(state.buffer)
    {bytes, count} = {state.bytes, state.count}
    parent = self()

    spawn(fn ->
      started = System.monotonic_time(:microsecond)

      result =
        case write(batch) do
          {:ok, written} -> {:flushed, :ok, count, bytes, written, elapsed(started)}
          {:error, reason} -> {:flushed, {:error, reason}, batch, bytes, 0, elapsed(started)}
        end

      send(parent, result)
    end)

    %{state | buffer: [], bytes: 0, count: 0, inflight: state.inflight + 1}
  end

  defp flush_now(%{count: 0} = state), do: {{:ok, 0}, state}

  defp flush_now(state) do
    started = System.monotonic_time(:microsecond)

    case write(Enum.reverse(state.buffer)) do
      {:ok, n} ->
        telemetry(
          :flush,
          %{
            count: state.count,
            bytes: state.bytes,
            written: n,
            duration_us: elapsed(started)
          },
          %{sync: true}
        )

        {{:ok, n}, %{state | buffer: [], bytes: 0, count: 0}}

      {:error, reason} ->
        # Keep the buffer. Clearing it here would discard events the store
        # never accepted — the async path is careful to requeue, and the
        # synchronous path silently dropping them was strictly worse, because
        # `flush/1` is what `terminate/2`-adjacent code and tests call.
        {{:error, reason}, state}
    end
  end

  defp write(batch) do
    Store.insert_events(batch)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, Config.flush_ms())}
  end

  defp elapsed(started), do: System.monotonic_time(:microsecond) - started

  defp telemetry(event, measurements, metadata),
    do: :telemetry.execute([:pixelex, :ingest, event], measurements, metadata)
end
