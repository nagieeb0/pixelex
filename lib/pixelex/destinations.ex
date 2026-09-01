defmodule Pixelex.Destinations do
  @moduledoc """
  One call, every ad platform a site has configured.

      Pixelex.Destinations.fire("shop", :purchase,
        event_id: "order:" <> order.id,
        event_source_url: url,
        user_data: %{email: patient.email, phone: patient.phone, ip: ip, fbclid: fbclid},
        custom_data: %{currency: "EGP", value: 1499.0}
      )

  Each platform no-ops without its own credentials, so a site that set up only
  Meta behaves exactly as though the others did not exist.

  ## `event_id` is the whole design

  The same id goes to every platform and to the browser pixel. Each platform
  deduplicates on it, so firing both legs counts one conversion — and, less
  obviously, it is what makes retrying safe. Derive it from the row it
  describes (`"order:\#{order.id}"`, never `UUID.generate()`) and a replay can
  never double-count. Everything else here depends on that.

  ## Delivery is durable, or it says so

  With `oban` installed, `fire/3` enqueues and
  `Pixelex.Destinations.Worker` makes the calls with five attempts. Without it,
  delivery falls back to an unsupervised task and logs a warning once — a
  deploy mid-flight then drops the conversion with no record and no retry,
  which is silent under-reporting of exactly the events ad spend optimises
  against.

  ## Secrets are not put in the queue

  The job carries a site id and an event name. Credentials are re-read when it
  runs. Writing decrypted access tokens into a database-backed job table would
  be strictly worse than the extra read, and rotating a token would leave stale
  secrets sitting in the queue.

  ## Configuring a site

      %{
        "meta"      => %{"pixel_id" => "…", "access_token" => "…"},
        "tiktok"    => %{"pixel_code" => "…", "access_token" => "…"},
        "snapchat"  => %{"pixel_id" => "…", "access_token" => "…"},
        "ga4"       => %{"measurement_id" => "G-…", "api_secret" => "…"}
      }

  in `pixelex_sites.destinations`, or under `config :pixelex, sites:`.
  Encrypting them at rest is the host's job — pixelex never logs them, but it
  cannot encrypt a column it does not own.
  """
  require Logger

  alias Pixelex.{Consent, Sites}

  @built_in [
    Pixelex.Destinations.Meta,
    Pixelex.Destinations.TikTok,
    Pixelex.Destinations.Snapchat,
    Pixelex.Destinations.GA4
  ]

  @canonical_events ~w(page_view view_content search add_to_cart initiate_checkout
                       add_payment_info purchase lead complete_registration
                       subscribe contact schedule)a

  # Credential keys are converted from the JSON column with
  # String.to_existing_atom against this list. Never String.to_atom on data
  # that came out of a database a tenant can write to.
  @credential_keys ~w(pixel_id pixel_code access_token api_secret measurement_id
                      test_event_code ad_account_id conversion_id dataset_id
                      tag_id account_id api_version partner_id)a

  @doc "The canonical events every destination maps from."
  @spec canonical_events() :: [atom()]
  def canonical_events, do: @canonical_events

  @doc "Destination modules in play — the built-ins, plus anything configured."
  @spec modules() :: [module()]
  def modules, do: Application.get_env(:pixelex, :destinations, @built_in)

  @doc """
  The whole canonical-event → platform-dialect table.

      Pixelex.Destinations.dialects()[:purchase]
      #=> %{meta: "Purchase", tiktok: "CompletePayment", snapchat: "PURCHASE", ga4: "purchase"}

  A `nil` means the platform genuinely has no equivalent.
  """
  @spec dialects() :: %{atom() => %{atom() => String.t() | nil}}
  def dialects do
    for event <- @canonical_events, into: %{} do
      {event, Map.new(modules(), &{&1.name(), &1.event_name(event)})}
    end
  end

  @doc """
  Queue `event` for every platform `site_id` has configured. Always `:ok`.

  Best-effort at the call site by design: a tracking problem is never the
  reason a booking or a payment fails.

  ## Options

    * `:event_id` — **required in practice.** Derive it from the row.
    * `:event_source_url`, `:action_source`
    * `:user_data` — raw, unhashed. Hashing happens per platform, at the edge.
    * `:custom_data` — `currency`, `value`, `content_ids`, …
    * `:consent` — signals from `Pixelex.Plug.Context`; omitted means no
      visitor is involved (a cron, an admin action) and no banner applies.
  """
  @spec fire(String.t(), atom(), keyword()) :: :ok
  def fire(site_id, event, opts \\ []) when is_binary(site_id) and is_atom(event) do
    with true <- event in @canonical_events,
         true <- consented?(opts) do
      enqueue(site_id, event, opts)
    else
      false -> log_ignored(event, site_id)
      {:denied, _reason} -> :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("[pixelex] destinations fire(#{inspect(event)}) failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Deliver synchronously to every configured platform. Called by the worker.

  **Deliberately not rescued.** A raise here fails the Oban job so it retries,
  which is the entire point of not using a fire-and-forget task.
  """
  @spec dispatch(String.t(), atom(), keyword()) :: [{atom(), :ok | {:error, term()}}]
  def dispatch(site_id, event, opts) do
    credentials_by_platform = credentials(site_id)
    conversion = conversion(opts)

    for module <- modules(),
        credentials = credentials_by_platform[module.name()],
        is_map(credentials),
        module.configured?(credentials),
        name = module.event_name(event),
        is_binary(name) do
      {module.name(), module.deliver(credentials, name, with_click_id(module, conversion))}
    end
  end

  @doc "A site's per-platform credentials, keys converted to atoms safely."
  @spec credentials(String.t()) :: %{atom() => map()}
  def credentials(site_id) do
    case Sites.get(site_id) do
      %Sites{destinations: destinations} when is_map(destinations) ->
        Map.new(destinations, fn {platform, creds} ->
          {safe_atom(platform), atomise(creds)}
        end)

      _ ->
        %{}
    end
  end

  # --- internals --------------------------------------------------------------

  defp enqueue(site_id, event, opts) do
    args = %{
      "site_id" => site_id,
      "event" => Atom.to_string(event),
      "event_id" => opts[:event_id],
      "event_time" => opts[:event_time] || System.system_time(:second),
      "event_source_url" => opts[:event_source_url],
      "action_source" => opts[:action_source],
      "user_data" => stringify(opts[:user_data]),
      "custom_data" => stringify(opts[:custom_data])
    }

    if oban?() do
      args
      |> Pixelex.Destinations.Worker.new()
      |> then(&apply(Oban, :insert, [&1]))
      |> case do
        {:ok, _job} -> :ok
        {:error, reason} -> log_failed(event, reason)
      end
    else
      warn_no_oban()
      Task.start(fn -> dispatch(site_id, event, from_args(args)) end)
      :ok
    end
  end

  @doc false
  def from_args(args) do
    [
      event_id: args["event_id"],
      event_time: args["event_time"],
      event_source_url: args["event_source_url"],
      action_source: args["action_source"],
      user_data: atomise(args["user_data"]),
      custom_data: atomise_custom(args["custom_data"])
    ]
  end

  defp conversion(opts) do
    %{
      event_id: opts[:event_id] || "",
      event_time: opts[:event_time] || System.system_time(:second),
      event_source_url: opts[:event_source_url],
      action_source: opts[:action_source],
      user_data: opts[:user_data] || %{},
      custom_data: opts[:custom_data] || %{},
      test_code: opts[:test_code]
    }
  end

  # `Pixelex.Attribution` captured one click id; each platform wants it under
  # its own key. Copying it across means a caller passes `click_id` once rather
  # than knowing all four spellings.
  defp with_click_id(module, conversion) do
    key = if function_exported?(module, :click_id_key, 0), do: module.click_id_key()
    generic = conversion.user_data[:click_id]

    if key && generic && is_nil(conversion.user_data[key]) do
      put_in(conversion, [:user_data, key], generic)
    else
      conversion
    end
  end

  defp consented?(opts) do
    case opts[:consent] do
      nil -> true
      signals -> Consent.destinations_allowed?(signals)
    end
  end

  defp atomise(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {safe_credential_atom(k), v}
    end
    |> Map.reject(fn {k, _v} -> k == :__unknown__ end)
  end

  defp atomise(_), do: %{}

  # user_data and custom_data carry more keys than credentials do, and they
  # come from the host rather than a tenant, so the allowlist is wider —
  # but it is still an allowlist, and still to_existing_atom.
  defp atomise_custom(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_atom(k), v} end)
  end

  defp atomise_custom(_), do: %{}

  defp safe_credential_atom(key) when is_atom(key), do: key

  defp safe_credential_atom(key) when is_binary(key) do
    atom = safe_atom(key)
    if atom in @credential_keys, do: atom, else: :__unknown__
  end

  defp safe_atom(key) when is_atom(key), do: key

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end

  defp stringify(map) when is_map(map) do
    for {k, v} <- map, not is_nil(v), into: %{}, do: {to_string(k), v}
  end

  defp stringify(_), do: %{}

  defp oban?, do: Code.ensure_loaded?(Oban) and not is_nil(Process.whereis(Oban))

  defp warn_no_oban do
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning("""
      [pixelex] delivering conversions without Oban.

      They ride an unsupervised task: a deploy or a crash mid-flight drops the
      conversion with no record and no retry. Since every event_id is derived
      from the row it describes, replays cannot double-count — which is exactly
      what makes retrying safe and worth having. Add {:oban, "~> 2.17"}.
      """)
    end
  end

  defp log_ignored(event, site_id) do
    Logger.warning("[pixelex] unknown canonical event #{inspect(event)} for site #{site_id}")
    :ok
  end

  defp log_failed(event, reason) do
    Logger.warning("[pixelex] could not enqueue #{inspect(event)}: #{inspect(reason)}")
    :ok
  end
end
