defmodule Pixelex.Store do
  @moduledoc """
  Where events go.

  Two adapters ship: `Pixelex.Store.Postgres` (the real one) and
  `Pixelex.Store.ETS` (tests, and a dev server that should not need a database
  to boot). ClickHouse via `ecto_ch` and DuckDB via `duckdbex` fit this
  behaviour without changes to anything above it, but neither is written —
  columnar storage earns its operational cost somewhere past the point where
  partitioned Postgres stops coping, and most apps never get there.

  ## The contract

  `insert_events/1` receives a batch and must be idempotent on `event.id`. The
  ingest buffer may replay a batch after a transient failure, and every event
  carries a UUIDv7 assigned once at creation, so a replay is a duplicate key
  rather than a duplicate row.
  """

  alias Pixelex.Event

  @doc """
  Write a batch. Must be idempotent on `event.id`.

  Returns the number of rows actually written — which is less than the batch
  size when a replay collided with rows already stored, and that is success,
  not failure.
  """
  @callback insert_events([Event.t()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Create whatever the adapter needs. Called by `mix pixelex.setup`; a no-op for stateless adapters."
  @callback setup() :: :ok | {:error, term()}

  @doc "Processes the adapter needs running, if any."
  @callback children() :: [Supervisor.child_spec() | {module(), term()} | module()]

  @optional_callbacks setup: 0, children: 0

  @doc "Write a batch through the configured adapter."
  @spec insert_events([Event.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_events([]), do: {:ok, 0}
  def insert_events(events), do: Pixelex.Config.store().insert_events(events)

  @doc "Child specs for the configured adapter, or `[]` when it needs none."
  @spec children() :: list()
  def children do
    store = Pixelex.Config.store()

    # Code.ensure_loaded?/1 first, and it is load-bearing: function_exported?/3
    # answers about a LOADED module and returns false for one that merely has
    # not been reached yet. This runs from Application.start/2, before anything
    # has referenced the adapter, so the bare check silently reported "no
    # children" for every adapter and the ETS table ended up owned by whichever
    # request first touched it — dying with that process.
    if Code.ensure_loaded?(store) and function_exported?(store, :children, 0) do
      store.children()
    else
      []
    end
  end
end
