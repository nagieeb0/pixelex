defmodule Pixelex.Destinations.Meta do
  @moduledoc """
  Meta Conversions API.

  Mirrors browser-pixel conversions from the server so they still land when the
  visitor blocks the pixel, and **deduplicates** against the browser
  `fbq('track', …, {eventID: id})` through a shared `event_id`.

  ## Credentials

      %{pixel_id: "123…", access_token: "EAA…", test_event_code: "TEST1234"}

  `test_event_code` shows the event in Events Manager's test tool without it
  counting — the only way to verify the payload shape without spending real
  attribution on a guess.

  ## `fbc`

  Meta matches a server conversion to the ad that paid for it through `fbc`,
  built from the `fbclid` captured at the click:

      fb.1.<unix_ms>.<fbclid>

  `Pixelex.Attribution` captures the `fbclid`; `fbc/2` builds the string. Pass
  the raw click id as `user_data.fbclid` and this does the rest. Without it a
  conversion is attributed to nothing, which is the same as not sending it.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @api_version "v21.0"
  @graph "https://graph.facebook.com"

  @events %{
    page_view: "PageView",
    view_content: "ViewContent",
    search: "Search",
    add_to_cart: "AddToCart",
    initiate_checkout: "InitiateCheckout",
    add_payment_info: "AddPaymentInfo",
    purchase: "Purchase",
    lead: "Lead",
    complete_registration: "CompleteRegistration",
    subscribe: "Subscribe",
    contact: "Contact",
    schedule: "Schedule"
  }

  @impl true
  def name, do: :meta

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :fbclid

  @impl true
  def configured?(%{pixel_id: pixel, access_token: token}),
    do: present?(pixel) and present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    url = "#{@graph}/#{@api_version}/#{credentials.pixel_id}/events"

    body =
      Hash.compact(%{
        data: [event(event_name, conversion)],
        access_token: credentials.access_token,
        test_event_code: conversion[:test_code] || credentials[:test_event_code]
      })

    HTTP.post(:meta, url, body)
  end

  @doc """
  Meta's click-id format: `fb.1.<unix_ms>.<fbclid>`.

  The `1` is the subdomain index and is not a version. The timestamp should be
  when the click happened, not when the conversion did — Meta uses it to place
  the click in an attribution window, so passing `now` for a click from three
  days ago quietly narrows the window it can match in.
  """
  @spec fbc(String.t() | nil, integer() | nil) :: String.t() | nil
  def fbc(fbclid, clicked_at_ms \\ nil)

  def fbc(nil, _clicked_at_ms), do: nil
  def fbc("", _clicked_at_ms), do: nil

  def fbc(fbclid, clicked_at_ms) when is_binary(fbclid) do
    "fb.1.#{clicked_at_ms || System.system_time(:millisecond)}.#{fbclid}"
  end

  defp event(event_name, conversion) do
    Hash.compact(%{
      event_name: event_name,
      event_time: conversion.event_time,
      event_id: conversion.event_id,
      event_source_url: conversion[:event_source_url],
      action_source: conversion[:action_source] || "website",
      user_data: user_data(conversion[:user_data] || %{}),
      custom_data: Hash.compact(conversion[:custom_data] || %{})
    })
  end

  # Meta takes hashed match keys as ARRAYS, and non-hashed ones as plain
  # strings. Sending a bare string where it expects an array is accepted with a
  # 200 and then matches nothing.
  defp user_data(ud) do
    Hash.compact(%{
      em: wrap(Hash.email(ud[:email])),
      ph: wrap(Hash.phone_digits(ud[:phone])),
      fn: wrap(Hash.text(ud[:first_name])),
      ln: wrap(Hash.text(ud[:last_name])),
      ct: wrap(Hash.text(ud[:city])),
      st: wrap(Hash.text(ud[:state])),
      zp: wrap(Hash.text(ud[:zip])),
      country: wrap(Hash.text(ud[:country])),
      external_id: wrap(Hash.text(ud[:external_id])),
      client_ip_address: ud[:ip],
      client_user_agent: ud[:user_agent],
      fbp: ud[:fbp],
      fbc: ud[:fbc] || fbc(ud[:fbclid], ud[:clicked_at_ms])
    })
  end

  defp wrap(nil), do: nil
  defp wrap(value), do: [value]

  defp present?(v), do: is_binary(v) and v != ""
end
