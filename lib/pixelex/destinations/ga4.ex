defmodule Pixelex.Destinations.GA4 do
  @moduledoc """
  GA4 Measurement Protocol, server-side.

  ## Credentials

      %{measurement_id: "G-XXXXXXXXXX", api_secret: "…"}

  The secret comes from GA4 Admin → Data Streams → Measurement Protocol API
  secrets. It is not the same thing as an API key and cannot be found anywhere
  else.

  ## GA4 is the odd one out, in three ways

  **No PII hashing.** There is no API for it. Sending an email address here
  would be both useless and a policy violation, so `user_data` is dropped
  entirely except for the `client_id`.

  **Identity is a `client_id`, not a match key.** Normally the browser's `_ga`
  cookie. Server-side it has to be forwarded by the caller; when it is not,
  this derives a stable pseudo-id from the `event_id` so retries collapse onto
  the same synthetic client. Those events record, but they will not stitch to
  the visitor's browser session the way Meta's and TikTok's `event_id` dedup
  does. That is a real limitation of the Measurement Protocol, not of this
  client — forward `client_id` whenever you have it.

  **Success is `204`, with no body.** A `200` with an HTML body means the
  request went somewhere else.

  ## Custom event names are fine here

  Unlike the ad platforms, GA4 accepts any event name and reports on it. Where
  there is no recommended equivalent — `contact`, `schedule` — the canonical
  name is sent in snake_case rather than dropped.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @endpoint "https://www.google-analytics.com/mp/collect"

  @events %{
    page_view: "page_view",
    view_content: "view_item",
    search: "search",
    add_to_cart: "add_to_cart",
    initiate_checkout: "begin_checkout",
    add_payment_info: "add_payment_info",
    purchase: "purchase",
    lead: "generate_lead",
    complete_registration: "sign_up",
    subscribe: "subscribe",
    contact: "contact",
    schedule: "schedule"
  }

  @impl true
  def name, do: :ga4

  @impl true
  def fields do
    [
      %{
        key: :measurement_id,
        label: "Measurement ID",
        placeholder: "G-XXXXXXXXXX",
        hint: "Admin -> Data streams -> your web stream. Starts with G-."
      },
      %{
        key: :api_secret,
        label: "API secret",
        secret: true,
        hint: "Same screen -> Measurement Protocol API secrets -> Create."
      }
    ]
  end

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :gclid

  @impl true
  def configured?(%{measurement_id: id, api_secret: secret}),
    do: present?(id) and present?(secret)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    url =
      @endpoint <>
        "?" <>
        URI.encode_query(
          measurement_id: credentials.measurement_id,
          api_secret: credentials.api_secret
        )

    body = %{
      client_id: client_id(conversion),
      events: [%{name: event_name, params: params(conversion)}]
    }

    HTTP.post(:ga4, url, body, success: &success?/1)
  end

  # The Measurement Protocol answers 204 with no body on success. It also
  # answers 2xx for a malformed payload it silently discarded, which is why the
  # debug endpoint exists and why this integration should be verified in GA4's
  # DebugView rather than by trusting the status code.
  defp success?(%{status: status}), do: status in 200..299

  defp client_id(conversion) do
    case conversion[:user_data][:client_id] do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        # A stable synthetic id, so a retried job is the same pseudo-client
        # rather than a new one each time.
        hash = Hash.digest(to_string(conversion.event_id))
        "#{String.slice(hash, 0, 10)}.#{String.slice(hash, 10, 10)}"
    end
  end

  defp params(conversion) do
    custom = conversion[:custom_data] || %{}

    Hash.compact(%{
      currency: custom[:currency] || custom["currency"],
      value: custom[:value] || custom["value"],
      transaction_id: conversion.event_id,
      page_location: conversion[:event_source_url],
      items: items(custom),
      # Without this, Measurement Protocol events do not count toward the
      # session and appear in reports detached from everything else.
      engagement_time_msec: 1,
      session_id: conversion[:user_data][:ga_session_id]
    })
  end

  defp items(custom) do
    ids = custom[:content_ids] || custom["content_ids"]
    name = custom[:content_name] || custom["content_name"]

    case ids do
      [id | _] -> [Hash.compact(%{item_id: to_string(id), item_name: name})]
      id when is_binary(id) -> [Hash.compact(%{item_id: id, item_name: name})]
      _ -> nil
    end
  end

  defp present?(v), do: is_binary(v) and v != ""
end
