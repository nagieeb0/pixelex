defmodule Pixelex.RateLimit do
  @moduledoc """
  A fixed-window counter in ETS. Enough to bound an open endpoint, and no more.

  `POST /px/e` is unauthenticated by necessity — most of the clicks worth
  counting happen before anyone signs in — so something has to stand between it
  and a script. Three things do, and none of them is auth: the per-site event
  allowlist, the consent gate, and this.

  ## Why not a rate-limiting library

  Because the requirement is "one number per IP per minute" and that is
  `:ets.update_counter/4`. Adding a dependency to every consumer's tree for
  twenty lines is the trade this library keeps declining.

  ## Ceiling

  A fixed window, not a sliding one, so a caller can send `2 × limit` across a
  window boundary. For the job — separating a human from a script by three
  orders of magnitude — that is irrelevant. ponytail: fixed window; swap in a
  sliding log if pixelex ever needs to bill on this rather than bound it.

  Per node, too: with three nodes behind a load balancer the effective limit is
  three times the configured one. Also fine, for the same reason.
  """

  @table :pixelex_rate_limit

  @doc """
  Count one hit against `key`. `{:allow, count}` or `{:deny, limit}`.

      iex> Pixelex.RateLimit.hit("test:\#{System.unique_integer()}", 60_000, 2)
      {:allow, 1}
  """
  @spec hit(String.t(), pos_integer(), pos_integer()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def hit(key, window_ms, limit) do
    ensure_table()
    bucket = div(System.system_time(:millisecond), window_ms)

    case :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0}) do
      count when count <= limit -> {:allow, count}
      _ -> {:deny, limit}
    end
  rescue
    # Never let the limiter itself be the reason a request fails. Failing open
    # loses the bound; failing closed loses the page.
    _ -> {:allow, 1}
  end

  @doc "Drop counters from windows that have passed. Cheap; call it on a timer."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(window_ms) do
    ensure_table()
    current = div(System.system_time(:millisecond), window_ms)

    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
  rescue
    _ -> 0
  end

  @doc false
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  defmodule Sweeper do
    @moduledoc false
    use GenServer

    @every_ms 5 * 60 * 1_000

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      Pixelex.RateLimit.reset()
      schedule()
      {:ok, %{}}
    end

    @impl true
    def handle_info(:sweep, state) do
      {window, _limit} = swap(Pixelex.Config.rate_limit())
      Pixelex.RateLimit.sweep(window)
      schedule()
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp swap({limit, window}), do: {window, limit}
    defp schedule, do: Process.send_after(self(), :sweep, @every_ms)
  end
end
