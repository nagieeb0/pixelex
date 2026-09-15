defmodule Pixelex.Sites do
  @moduledoc """
  Per-tenant configuration, cached in ETS.

  A site owns its domain, the event names a browser is allowed to send, its
  ad-platform credentials, and its retention window. All of it lives in
  `pixelex_sites` rather than in application config, because a library cannot
  know a tenant's event names at compile time — that was the one thing wrong
  with every version of this code that came before it.

  ## Why the cache is not optional

  `POST /px/e` runs the allowlist check on every single event. Reading a row
  per event would put the busiest query in the system on the request path of
  the cheapest operation in it. Sites change rarely, so a read-through ETS
  cache with a TTL is the whole design; `refresh/1` invalidates on write.

  ## The allowlist

  An unauthenticated endpoint that writes whatever string it is handed is a
  table anyone on the internet can fill, and the damage is not the disk — it is
  that every number on the dashboard becomes a claim that cannot be defended.
  So the **server** decides what exists. An unknown name is dropped silently
  and the endpoint answers 204 either way: telling a scanner which names are
  real is free help.

  `allow_any_event: true` turns the allowlist off, for sites that only ever
  emit events from trusted server-side code.
  """
  require Logger

  alias Pixelex.Config

  @table :pixelex_sites_cache
  @ttl_ms 60_000

  defstruct id: nil,
            domain: nil,
            allowed_events: [],
            allow_any_event: false,
            destinations: %{},
            retention_days: nil

  @type t :: %__MODULE__{}

  @doc """
  Fetch a site, from cache when warm.

  Returns `nil` for an unknown id — the caller drops the event. An
  auto-provisioning default would mean a typo in a tracking snippet silently
  creates a tenant.
  """
  @spec get(String.t()) :: t() | nil
  def get(site_id) when is_binary(site_id) do
    case configured(site_id) do
      %__MODULE__{} = site ->
        site

      nil ->
        case cached(site_id) do
          {:hit, site} -> site
          :miss -> load_and_cache(site_id)
        end
    end
  end

  def get(_), do: nil

  @doc "May this site record an event with this name from a browser?"
  @spec allowed_event?(t() | nil, String.t()) :: boolean()
  def allowed_event?(nil, _name), do: false
  def allowed_event?(%__MODULE__{allow_any_event: true}, _name), do: true

  def allowed_event?(%__MODULE__{allowed_events: allowed}, name) when is_binary(name) do
    # The tracker can only emit this closed set under pixelex's reserved
    # namespace. A host should not need to copy library-owned event names into
    # every tenant row, while an invented `px.anything` must still be refused.
    name in allowed or name in Pixelex.Pipeline.browser_events()
  end

  def allowed_event?(_, _), do: false

  @doc "Create or update a site. Invalidates the cache."
  @spec put(map()) :: {:ok, t()} | {:error, term()}
  def put(%{id: id} = attrs) when is_binary(id) do
    now = DateTime.utc_now()

    sql!(
      """
      INSERT INTO pixelex_sites
        (id, domain, allowed_events, allow_any_event, destinations, retention_days,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      ON CONFLICT (id) DO UPDATE SET
        domain = EXCLUDED.domain,
        allowed_events = EXCLUDED.allowed_events,
        allow_any_event = EXCLUDED.allow_any_event,
        destinations = EXCLUDED.destinations,
        retention_days = EXCLUDED.retention_days,
        updated_at = EXCLUDED.updated_at
      """,
      [
        id,
        attrs[:domain],
        attrs[:allowed_events] || [],
        attrs[:allow_any_event] || false,
        attrs[:destinations] || %{},
        attrs[:retention_days],
        now
      ]
    )

    refresh(id)
    {:ok, get(id)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Merge `attrs` into a site, leaving every column you did not name alone.

  Read-modify-write rather than a dynamic `UPDATE`. Sites change roughly never
  and only from an admin screen, so the lost-update window is theoretical,
  while hand-built partial SQL is a real source of bugs forever.
  """
  @spec update(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update(site_id, attrs) when is_binary(site_id) and is_map(attrs) do
    current = get(site_id) || %__MODULE__{id: site_id}

    current
    |> Map.from_struct()
    |> Map.merge(Map.new(attrs))
    |> Map.put(:id, site_id)
    |> put()
  end

  @doc "Drop a site from the cache, so the next read reloads it."
  @spec refresh(String.t()) :: :ok
  def refresh(site_id) do
    ensure_table()
    :ets.delete(@table, site_id)
    :ok
  end

  @doc false
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  A site declared in application config rather than the database.

      config :pixelex,
        sites: %{
          "shop" => [
            domain: "shop.test",
            allowed_events: ~w(book_click call_click order_started)
          ]
        }

  Most applications have exactly one site, and making them run a migration,
  write an admin screen and insert a row before a single page view is counted
  is a bad first five minutes. Config is checked first: it is explicit, it
  costs no query, and it is version-controlled alongside the `data-track`
  attributes whose names it lists.

  The table is for the multi-tenant case, where sites are created by users at
  runtime and cannot be known when the release is built.
  """
  @spec configured(String.t()) :: t() | nil
  def configured(site_id) do
    case Application.get_env(:pixelex, :sites, %{})[site_id] do
      nil ->
        nil

      attrs ->
        attrs = Map.new(attrs)

        %__MODULE__{
          id: site_id,
          domain: attrs[:domain],
          allowed_events: attrs[:allowed_events] || [],
          allow_any_event: attrs[:allow_any_event] || false,
          destinations: attrs[:destinations] || %{},
          retention_days: attrs[:retention_days]
        }
    end
  rescue
    _ -> nil
  end

  # --- internals ------------------------------------------------------------

  defp cached(site_id) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, site_id) do
      [{^site_id, site, expires}] when expires > now -> {:hit, site}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # Two different nils, and conflating them is a real fault either way:
  #
  #   * the site does not exist -> CACHE the nil. Otherwise a typo in one
  #     tracking snippet, or a scanner walking site ids, sends a database query
  #     per request forever.
  #   * the database errored     -> DO NOT cache. Caching it would turn a
  #     three-second blip into a minute of every event rejected for every site.
  defp load_and_cache(site_id) do
    case load(site_id) do
      {:ok, site} ->
        ensure_table()
        :ets.insert(@table, {site_id, site, System.monotonic_time(:millisecond) + @ttl_ms})
        site

      :error ->
        nil
    end
  end

  defp load(site_id) do
    case sql!(
           """
           SELECT id, domain, allowed_events, allow_any_event, destinations, retention_days
           FROM pixelex_sites WHERE id = $1
           """,
           [site_id]
         ) do
      %{rows: [[id, domain, allowed, any?, destinations, retention]]} ->
        {:ok,
         %__MODULE__{
           id: id,
           domain: domain,
           allowed_events: allowed || [],
           allow_any_event: any? || false,
           destinations: destinations || %{},
           retention_days: retention
         }}

      _ ->
        {:ok, nil}
    end
  rescue
    e ->
      Logger.warning("Pixelex site load failed for #{inspect(site_id)}: #{inspect(e)}")
      :error
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  defp sql!(query, params) do
    repo = Config.repo() || raise "Pixelex needs `config :pixelex, repo: MyApp.Repo`"
    Ecto.Adapters.SQL.query!(repo, query, params)
  end
end
