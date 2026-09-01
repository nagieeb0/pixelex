defmodule Pixelex.Store.ETS do
  @moduledoc """
  An in-memory store. For tests, and for a dev server that should boot without
  a database.

  It exists for a second reason: a behaviour with one implementation is a
  behaviour nobody has checked. Having `Postgres` and `ETS` both satisfy
  `Pixelex.Store` is what proves the seam is real, and it is where an adapter
  author looks first.

  Bounded by `Pixelex.Config.max_buffer/0` — it drops the oldest events past
  that. Losing history in a dev store is correct; running a laptop out of
  memory is not.
  """
  @behaviour Pixelex.Store

  @table :pixelex_events_ets

  @impl true
  def children, do: [{__MODULE__.Owner, []}]

  @impl true
  def setup do
    ensure_table()
    :ok
  end

  @impl true
  def insert_events(events) do
    ensure_table()

    written =
      Enum.count(events, fn event ->
        # insert_new so a replayed batch collides rather than duplicating,
        # matching the Postgres adapter's ON CONFLICT DO NOTHING.
        :ets.insert_new(@table, {event.id, event})
      end)

    trim()
    {:ok, written}
  rescue
    e -> {:error, e}
  end

  @doc "Every stored event, oldest first. Test helper — never call this on a real store."
  def all do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.id)
  end

  @doc "Drop everything. Test helper."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def table, do: @table

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _ ->
        @table
    end
  rescue
    # Two processes racing to create the same named table: the loser sees
    # ArgumentError and the table it wanted now exists, which is the goal.
    ArgumentError -> @table
  end

  # Sorted by UUIDv7, so "oldest" is simply the smallest key.
  defp trim do
    max = Pixelex.Config.max_buffer()

    case :ets.info(@table, :size) do
      size when is_integer(size) and size > max ->
        @table
        |> :ets.tab2list()
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
        |> Enum.take(size - max)
        |> Enum.each(&:ets.delete(@table, &1))

      _ ->
        :ok
    end
  end

  defmodule Owner do
    @moduledoc """
    Owns the ETS table so it outlives the process that first wrote to it.

    Without an owner the table dies with whichever request happened to create
    it, and the next request silently starts a fresh one.
    """
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      Pixelex.Store.ETS.setup()
      {:ok, %{}}
    end
  end
end
