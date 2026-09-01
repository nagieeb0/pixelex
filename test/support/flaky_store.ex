defmodule Pixelex.Test.FlakyStore do
  @moduledoc """
  A store whose next N writes fail, so the buffer's requeue and give-up paths
  can be exercised without waiting for a real database to break.
  """
  @behaviour Pixelex.Store

  @key {__MODULE__, :failures}

  def fail_next(n), do: :persistent_term.put(@key, n)
  def reset, do: :persistent_term.put(@key, 0)
  def remaining, do: :persistent_term.get(@key, 0)

  @impl true
  def insert_events(events) do
    case remaining() do
      n when n > 0 ->
        :persistent_term.put(@key, n - 1)
        {:error, :store_unavailable}

      _ ->
        Pixelex.Store.ETS.insert_events(events)
    end
  end

  @impl true
  def setup, do: Pixelex.Store.ETS.setup()
end
