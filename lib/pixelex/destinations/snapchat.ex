defmodule Pixelex.Destinations.Snapchat do
  @moduledoc """
  Snapchat Conversions API (v3), server-side.

  Deduplicates against the browser `snaptr('track', …, {event_id})` through a
  shared `event_id`. The v3 payload mirrors Meta's closely — hashed match keys
  as arrays, `custom_data`, `action_source` — with `WEB` upper-cased and event
  names in `SCREAMING_SNAKE_CASE`.

  ## Credentials

      %{pixel_id: "…", access_token: "…"}

  From Snapchat Ads Manager → Events Manager → Conversions API.

  ## The taxonomy is smaller than the others

  Snapchat has no separate registration event, so `:lead` and
  `:complete_registration` both map to `SIGN_UP`. That is Snapchat's vocabulary
  rather than a copy-paste: their reporting genuinely does not distinguish the
  two.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @base "https://tr.snapchat.com/v3"

  @events %{
    page_view: "PAGE_VIEW",
    view_content: "VIEW_CONTENT",
    search: "SEARCH",
    add_to_cart: "ADD_CART",
    initiate_checkout: "START_CHECKOUT",
    add_payment_info: "ADD_BILLING",
    purchase: "PURCHASE",
    lead: "SIGN_UP",
    complete_registration: "SIGN_UP",
    subscribe: "SUBSCRIBE",
    contact: nil,
    schedule: "RESERVE"
  }

  @impl true
  def name, do: :snapchat

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :sc_click_id

  @impl true
  def configured?(%{pixel_id: pixel, access_token: token}),
    do: present?(pixel) and present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    url =
      "#{@base}/#{credentials.pixel_id}/events?access_token=" <>
        URI.encode_www_form(credentials.access_token)

    HTTP.post(:snapchat, url, %{data: [event(event_name, conversion)]})
  end

  defp event(event_name, conversion) do
    Hash.compact(%{
      event_name: event_name,
      event_time: conversion.event_time,
      event_id: conversion.event_id,
      event_source_url: conversion[:event_source_url],
      action_source: conversion[:action_source] || "WEB",
      user_data: user_data(conversion[:user_data] || %{}),
      custom_data: Hash.compact(conversion[:custom_data] || %{})
    })
  end

  defp user_data(ud) do
    Hash.compact(%{
      em: wrap(Hash.email(ud[:email])),
      ph: wrap(Hash.phone_digits(ud[:phone])),
      client_ip_address: ud[:ip],
      client_user_agent: ud[:user_agent],
      sc_click_id: ud[:sc_click_id] || ud[:sccid],
      sc_cookie1: ud[:sc_cookie1]
    })
  end

  defp wrap(nil), do: nil
  defp wrap(value), do: [value]

  defp present?(v), do: is_binary(v) and v != ""
end
