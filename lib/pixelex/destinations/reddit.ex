defmodule Pixelex.Destinations.Reddit do
  @moduledoc """
  Reddit Conversions API v3.

  v3 landed on 1 October 2025 and changed enough that any pre-2026 example is
  actively misleading: the body gained a `data` wrapper, `event_at` moved from
  ISO 8601 to Unix **milliseconds**, `action_source` became required, and the
  event vocabulary went from `PageVisit` to `PAGE_VISIT`. Copy from an old blog
  post and you silently create custom events named after standard ones.

  ## Credentials

      %{pixel_id: "a2_…", access_token: "…"}

  A non-expiring conversion access token from Events Manager → Configure data
  source → Conversions API is the recommended path; an OAuth2 developer token
  with the `adsconversions` scope also works.

  ## Reddit's email rule is nobody else's

  Lower-case, strip dots from the local part, drop everything after a `+`. So
  `Al.ice+Apple@Example.Com` and `alice@example.com` hash identically.
  `Pixelex.Destinations.Hash.email_reddit/1` implements it and is checked
  against Reddit's published vector. Phone is E.164 with the `+` **kept**,
  which is TikTok's rule and the opposite of Pinterest's.

  ## A descriptive user agent is not optional

  Reddit rate-limits generic agents by name. This sends
  `elixir:pixelex:<version>`.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @endpoint "https://ads-api.reddit.com/api/v3/pixels"

  # The complete v3 enum. Anything else has to travel as CUSTOM.
  @standard ~w(PAGE_VISIT VIEW_CONTENT SEARCH ADD_TO_CART ADD_TO_WISHLIST
               PURCHASE LEAD SIGN_UP)

  @events %{
    page_view: "PAGE_VISIT",
    view_content: "VIEW_CONTENT",
    search: "SEARCH",
    add_to_cart: "ADD_TO_CART",
    purchase: "PURCHASE",
    lead: "LEAD",
    complete_registration: "SIGN_UP",
    # No standard type exists for these. They travel as CUSTOM with a name,
    # which is Reddit's own documented answer rather than an invention.
    initiate_checkout: "InitiateCheckout",
    add_payment_info: "AddPaymentInfo",
    subscribe: "Subscribe",
    contact: "Contact",
    schedule: "Schedule"
  }

  @impl true
  def name, do: :reddit

  @impl true
  def fields do
    [
      %{
        key: :pixel_id,
        label: "Pixel ID",
        placeholder: "a2_xxxxxxxxxx",
        hint: "Ads -> Events Manager. Starts with a2_ or t2_."
      },
      %{
        key: :access_token,
        label: "Access token",
        secret: true,
        hint: "Reddit Ads API OAuth token."
      }
    ]
  end

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :rdt_cid

  @impl true
  def configured?(%{pixel_id: pixel, access_token: token}),
    do: present?(pixel) and present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    url = "#{@endpoint}/#{credentials.pixel_id}/conversion_events"

    HTTP.post(:reddit, url, %{data: %{events: [event(event_name, conversion)]}},
      headers: [
        {"authorization", "Bearer " <> credentials.access_token},
        {"user-agent", user_agent()}
      ]
    )
  end

  defp event(event_name, conversion) do
    Hash.compact(%{
      # Milliseconds, not seconds. Reddit rejects an event more than seven days
      # old and will not deduplicate one more than two days old.
      event_at: conversion.event_time * 1_000,
      action_source: conversion[:action_source] || "WEBSITE",
      type: type(event_name),
      event_source_url: conversion[:event_source_url],
      click_id: click_id(conversion),
      user: user(conversion[:user_data] || %{}),
      metadata: metadata(conversion)
    })
  end

  defp type(event_name) when event_name in @standard, do: %{tracking_type: event_name}

  defp type(custom_name),
    do: %{tracking_type: "CUSTOM", custom_event_name: custom_name}

  defp user(ud) do
    Hash.compact(%{
      email: Hash.email_reddit(ud[:email]),
      phone_number: Hash.phone_e164(ud[:phone]),
      external_id: ud[:external_id],
      ip_address: ud[:ip],
      user_agent: ud[:user_agent],
      # The first-party `_rdt_uuid` cookie, sent as-is and never hashed.
      uuid: ud[:rdt_uuid],
      aaid: ud[:aaid],
      idfa: ud[:idfa]
    })
  end

  defp metadata(conversion) do
    custom = conversion[:custom_data] || %{}

    Hash.compact(%{
      # Reddit's dedup key is metadata.conversion_id, not the event id — the
      # one platform here that does not call it event_id.
      conversion_id: conversion.event_id,
      currency: custom[:currency] || custom["currency"],
      value: custom[:value] || custom["value"],
      item_count: custom[:num_items] || custom["num_items"]
    })
  end

  # Reddit also extracts the click id from event_source_url when it is absent,
  # but sending it explicitly is more reliable than relying on that.
  defp click_id(conversion) do
    ud = conversion[:user_data] || %{}
    ud[:rdt_cid] || ud[:click_id]
  end

  defp user_agent do
    version =
      case :application.get_key(:pixelex, :vsn) do
        {:ok, vsn} -> List.to_string(vsn)
        _ -> "0.0.0"
      end

    "elixir:pixelex:#{version} (+https://hex.pm/packages/pixelex)"
  end

  defp present?(v), do: is_binary(v) and v != ""
end
