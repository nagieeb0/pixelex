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

  With `oban` running, `fire/3` enqueues and
  `Pixelex.Destinations.Worker` makes the calls with five attempts. Without it,
  delivery falls back to an unsupervised task and logs a warning once — a
  deploy mid-flight then drops the conversion with no record and no retry,
  which is silent under-reporting of exactly the events ad spend optimises
  against.

  Oban is found through `Oban.Registry`, which is where it registers; a custom
  instance name goes in `config :pixelex, oban_name: MyApp.Oban`.

  ## Secrets are not put in the queue

  The job carries a site id and an event name. Credentials are re-read when it
  runs. Writing decrypted access tokens into a database-backed job table would
  be strictly worse than the extra read, and rotating a token would leave stale
  secrets sitting in the queue.

  ## Configuring a site

  Two ways, and the first is the one most people want:

    * **the dashboard.** `pixelex_settings "/analytics/settings"` mounts
      `Pixelex.Dashboard.Settings`, where a tenant pastes the snippet their ad
      platform gave them and clicks Test. See that module.
    * **`config :pixelex, sites:`**, for a single-tenant app that keeps its
      credentials with the rest of its secrets. Config wins over the database,
      so a site defined there cannot be edited from the dashboard — the
      settings screen says so rather than saving into a void.

  Either way the shape is the same:

      %{
        "meta"      => %{"pixel_id" => "…", "access_token" => "…"},
        "tiktok"    => %{"pixel_code" => "…", "access_token" => "…"},
        "snapchat"  => %{"pixel_id" => "…", "access_token" => "…"},
        "ga4"       => %{"measurement_id" => "G-…", "api_secret" => "…"}
      }

  Set `config :pixelex, secret_key:` and everything marked `secret` in a
  destination's `c:Pixelex.Destination.fields/0` is encrypted at rest by
  `Pixelex.Secrets`. Without a key it is stored as given, which is the right
  default only while the credentials come from config in the first place.
  """
  require Logger

  alias Pixelex.{Consent, Sites}
  alias Pixelex.Destinations.Detect

  @built_in [
    Pixelex.Destinations.Meta,
    Pixelex.Destinations.TikTok,
    Pixelex.Destinations.Snapchat,
    Pixelex.Destinations.GA4,
    Pixelex.Destinations.Pinterest,
    Pixelex.Destinations.Reddit,
    Pixelex.Destinations.LinkedIn
  ]

  # X (Twitter) is deliberately absent. Its endpoint and payload are known, but
  # it requires OAuth 1.0a request signing, its own "API Reference" link for the
  # conversions endpoint 404s so there is no field-level specification, and the
  # simpler `X-Pixel-Token` header that would avoid the signer appears only in
  # third-party write-ups and a forum thread — nowhere in X's documentation.
  # Shipping a guessed endpoint is worse than shipping six platforms.

  @canonical_events ~w(page_view view_content search add_to_cart initiate_checkout
                       add_payment_info purchase lead complete_registration
                       subscribe contact schedule)a

  # Credential keys are converted from the JSON column with
  # String.to_existing_atom against this list. Never String.to_atom on data
  # that came out of a database a tenant can write to.
  @credential_keys ~w(pixel_id pixel_code access_token api_secret measurement_id
                      test_event_code ad_account_id conversion_id dataset_id
                      tag_id account_id api_version partner_id conversions)a

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

  @doc """
  A site's per-platform credentials, atomised and decrypted.

  Secret fields stored by `Pixelex.Dashboard.Settings` come back out of
  `Pixelex.Secrets`; a value that cannot be decrypted is dropped, so the
  platform reads as unconfigured rather than authenticating with ciphertext.
  """
  @spec credentials(String.t()) :: %{atom() => map()}
  def credentials(site_id) do
    case Sites.get(site_id) do
      %Sites{destinations: destinations} when is_map(destinations) ->
        Map.new(destinations, fn {platform, creds} ->
          name = safe_atom(platform)
          {name, creds |> atomise() |> decrypt_secrets(name)}
        end)

      _ ->
        %{}
    end
  end

  @doc """
  The form a platform needs, from its `c:Pixelex.Destination.fields/0`.

  `[]` for a destination that does not implement the callback: it still
  delivers, it just cannot be set up from the dashboard.
  """
  @spec fields(module() | atom()) :: [Pixelex.Destination.field()]
  def fields(platform) when is_atom(platform) do
    case module(platform) do
      nil -> []
      module -> if function_exported?(module, :fields, 0), do: module.fields(), else: []
    end
  end

  @doc "Every configurable platform, as `{module, fields}`, in `modules/0` order."
  @spec configurable() :: [{module(), [Pixelex.Destination.field()]}]
  def configurable do
    for module <- modules(), fields = fields(module.name()), fields != [], do: {module, fields}
  end

  @doc "The destination module answering to `platform`, or `nil`."
  @spec module(module() | atom()) :: module() | nil
  def module(platform) when is_atom(platform) do
    Enum.find(modules(), &(&1 == platform or &1.name() == platform))
  end

  @doc """
  Save one platform's credentials for a site.

  Everything the settings screen needs, in one call:

    * ids are run through `Pixelex.Destinations.Detect` so a pasted `<script>`
      snippet works exactly as well as a typed id
    * a **blank secret keeps the stored one** — the form never receives it, so
      a blank field means "unchanged", not "erase"
    * a **blank anything else clears it** — that box was rendered with its
      current value, so leaving it empty is a deliberate erase. Passing a
      partial map therefore drops the keys it omits; pass the whole platform
    * secrets are encrypted through `Pixelex.Secrets` when a key is configured
    * other platforms on the site are untouched

  Refuses a site defined in `config :pixelex, sites:`, which the database can
  never override — a silent no-op there would be a save button that lies.
  """
  @spec put_credentials(String.t(), atom(), map()) :: {:ok, Sites.t()} | {:error, term()}
  def put_credentials(site_id, platform, attrs)
      when is_binary(site_id) and is_atom(platform) and is_map(attrs) do
    cond do
      Sites.configured(site_id) ->
        {:error, :config_defined}

      fields(platform) == [] ->
        {:error, :unknown_platform}

      true ->
        key = Atom.to_string(platform)
        existing = stored(site_id, key)
        merged = merge_fields(fields(platform), attrs, existing, platform)

        destinations =
          site_destinations(site_id)
          |> Map.put(key, merged)

        Sites.update(site_id, %{destinations: destinations})
    end
  end

  @doc "Forget one platform's credentials entirely."
  @spec delete_credentials(String.t(), atom()) :: {:ok, Sites.t()} | {:error, term()}
  def delete_credentials(site_id, platform) when is_binary(site_id) and is_atom(platform) do
    if Sites.configured(site_id) do
      {:error, :config_defined}
    else
      destinations = Map.delete(site_destinations(site_id), Atom.to_string(platform))
      Sites.update(site_id, %{destinations: destinations})
    end
  end

  @doc """
  Send one real `page_view` to one platform and report what it said.

  The point of the settings screen: credentials are only ever wrong in ways
  that surface as a silent gap in reporting three weeks later. A round trip at
  save time turns that into a red line under a text box.

  The `event_id` is random here — the one place in this library where that is
  correct, because a deterministic id would be deduplicated away and the second
  test would report success without a request leaving the building. Meta's
  `test_event_code` is used when set, so the event lands in Test Events rather
  than in the advertiser's real numbers.
  """
  @spec test(String.t(), atom()) :: :ok | {:error, term()}
  def test(site_id, platform) when is_binary(site_id) and is_atom(platform) do
    with {:module, module} when not is_nil(module) <- {:module, module(platform)},
         credentials = credentials(site_id)[module.name()],
         {:configured, true} <-
           {:configured, is_map(credentials) and module.configured?(credentials)},
         {:event, name} when is_binary(name) <- {:event, module.event_name(:page_view)} do
      module.deliver(credentials, name, test_conversion(site_id, credentials))
    else
      {:module, nil} -> {:error, :unknown_platform}
      {:configured, false} -> {:error, :not_configured}
      {:event, _} -> {:error, :no_page_view_event}
    end
  rescue
    e -> {:error, e}
  end

  # --- internals --------------------------------------------------------------

  defp secret_keys(platform) do
    for %{key: key} = field <- fields(platform), field[:secret], do: key
  end

  defp decrypt_secrets(credentials, platform) do
    Enum.reduce(secret_keys(platform), credentials, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_binary(value) ->
          case Pixelex.Secrets.decrypt(value) do
            nil -> Map.delete(acc, key)
            plain -> Map.put(acc, key, plain)
          end

        _ ->
          acc
      end
    end)
  end

  defp site_destinations(site_id) do
    case Sites.get(site_id) do
      %Sites{destinations: destinations} when is_map(destinations) -> destinations
      _ -> %{}
    end
  end

  defp stored(site_id, platform_key) do
    case site_destinations(site_id)[platform_key] do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # Blank means "leave it alone" for a secret and "remove it" for anything
  # else. The asymmetry is the whole reason this is one function: the form
  # cannot render a secret back, so an empty secret box carries no information
  # about intent, while an empty pixel-id box carries all of it. Clearing a
  # secret is `delete_credentials/2`, which is a button that says so.
  defp merge_fields(fields, attrs, existing, platform) do
    Enum.reduce(fields, %{}, fn %{key: key} = field, acc ->
      name = Atom.to_string(key)
      raw = attrs[name] || attrs[key]

      value =
        cond do
          field[:type] == :map -> parse_rules(raw) || existing[name]
          field[:secret] -> encrypt_or_keep(raw, existing[name])
          true -> blank_to_nil(Detect.clean(platform, key, raw || ""))
        end

      if is_nil(value), do: acc, else: Map.put(acc, name, value)
    end)
  end

  defp encrypt_or_keep(raw, existing) do
    case blank_to_nil(raw) do
      nil -> existing
      value -> Pixelex.Secrets.encrypt(String.trim(value))
    end
  end

  # LinkedIn's conversion rules, as `purchase=12345678` per line. A map field
  # is rare enough that a textarea beats a nested form, and this is the parser
  # for it.
  defp parse_rules(raw) when is_binary(raw) do
    rules =
      raw
      |> String.split(~r/[\n,;]/, trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [event, id] ->
            event = event |> String.trim() |> String.downcase()
            id = String.trim(id)
            if event != "" and id != "", do: [{event, id}], else: []

          _ ->
            []
        end
      end)
      |> Map.new()

    if rules == %{}, do: nil, else: rules
  end

  defp parse_rules(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp test_conversion(site_id, credentials) do
    %{
      event_id:
        "pixelex-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      event_time: System.system_time(:second),
      event_source_url: test_url(site_id),
      action_source: "website",
      user_data: %{},
      custom_data: %{},
      test_code: credentials[:test_event_code]
    }
  end

  defp test_url(site_id) do
    host =
      case Sites.get(site_id) do
        %Sites{domain: domain} when is_binary(domain) and domain != "" -> domain
        _ -> site_id
      end

    "https://" <> String.replace_prefix(host, "https://", "")
  end

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
      |> then(&apply(Oban, :insert, [oban_name(), &1]))
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
      user_data: atomise_user(args["user_data"]),
      # Untouched, string keys and all. Meta, TikTok, Snapchat and Pinterest
      # forward the whole map to the platform, so an allowlist here would
      # silently drop a host's own custom properties; and every named read in
      # the clients is `custom[:currency] || custom["currency"]`, so the string
      # keys that come back out of the queue are read correctly as they are.
      custom_data: args["custom_data"] || %{}
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

  # The match keys the destination clients actually read, gathered from all
  # seven. An allowlist rather than a bare `to_existing_atom`, and separate
  # from @credential_keys — which is the bug this replaced: `from_args/1` ran
  # user_data through the CREDENTIAL allowlist, so `email`, `phone`, `ip`,
  # `user_agent` and every click id were dropped between the enqueue and the
  # platform client. Both delivery paths went through it, so until 0.3.0 every
  # conversion pixelex sent arrived with `user_data: %{}` — which Meta rejects
  # outright and the rest accept while matching nobody.
  @user_data_keys ~w(email phone first_name last_name city state zip country
                     company title external_id ip user_agent click_id
                     fbp fbc fbclid clicked_at_ms ttclid ttp sccid sc_click_id
                     sc_cookie1 rdt_cid rdt_uuid epik li_fat_id gclid
                     client_id ga_session_id aaid idfa)a

  defp atomise_user(map) when is_map(map) do
    for {key, value} <- map,
        atom = safe_atom(key),
        atom in @user_data_keys,
        into: %{},
        do: {atom, value}
  end

  defp atomise_user(_), do: %{}

  defp atomise(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {safe_credential_atom(k), v}
    end
    |> Map.reject(fn {k, _v} -> k == :__unknown__ end)
  end

  defp atomise(_), do: %{}

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

  @doc """
  The Oban instance to enqueue into. `config :pixelex, oban_name: MyApp.Oban`.

  Defaults to `Oban`, which is the name `Oban.start_link/1` uses when you do
  not pass one.
  """
  @spec oban_name() :: atom()
  def oban_name, do: Application.get_env(:pixelex, :oban_name, Oban)

  # Oban registers its supervisor through `Oban.Registry` — see
  # `Supervisor.start_link(__MODULE__, conf, name: Registry.via(conf.name, ...))`
  # in Oban itself — never under the local process name. `Process.whereis(Oban)`
  # is therefore `nil` on a perfectly healthy Oban, which is what this checked
  # until 0.3.0: every conversion took the fire-and-forget branch, and every
  # host that had already installed Oban was told to install Oban.
  defp oban? do
    Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Oban.Registry) and
      not is_nil(apply(Oban.Registry, :whereis, [oban_name()]))
  rescue
    _ -> false
  end

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
