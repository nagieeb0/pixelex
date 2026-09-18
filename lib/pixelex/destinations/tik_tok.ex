defmodule Pixelex.Destinations.TikTok do
  @moduledoc """
  TikTok Events API (v1.3), server-side.

  Deduplicates against the browser `ttq.track(…, {event_id})` through a shared
  `event_id`.

  ## Credentials

      %{pixel_code: "C8…", access_token: "…"}

  From TikTok Events Manager → Settings → Events API.

  ## Two things TikTok does differently

  **Phone numbers keep the `+`.** Meta and Snapchat hash digits only; TikTok
  hashes E.164 including the leading plus. Getting this wrong produces a valid
  request, a 200 response, and zero matches.

  **A 200 is not success.** TikTok answers `200` with `{"code": 40001, …}` for
  a rejected event. Treating the status alone as delivery is how a broken
  integration reports itself healthy for a month, so the check here is on
  `code == 0`.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @endpoint "https://business-api.tiktok.com/open_api/v1.3/event/track/"

  @events %{
    page_view: "Pageview",
    view_content: "ViewContent",
    search: "Search",
    add_to_cart: "AddToCart",
    initiate_checkout: "InitiateCheckout",
    add_payment_info: "AddPaymentInfo",
    purchase: "CompletePayment",
    lead: "SubmitForm",
    complete_registration: "CompleteRegistration",
    subscribe: "Subscribe",
    contact: "Contact",
    # **TikTok has no booking event, so a booking is a form submission.**
    #
    # This was `nil`, on the reasoning that TikTok's catalogue has nothing for an
    # appointment and inventing one would create a conversion the advertiser
    # cannot optimise toward. The first half is true. The second half is what
    # `nil` actually costs: an advertiser running bookings off TikTok got
    # **nothing at all** when one happened — no conversion, no signal, no
    # optimisation target — while every other destination here reported it.
    # That is not the advertiser being protected from a bad mapping, it is the
    # advertiser being handed a dark channel.
    #
    # `SubmitForm` is TikTok's standard lead event and is optimisable. It is
    # already this file's `lead`, so the mapping is verified rather than
    # remembered — and folding two canonical events onto one platform event is
    # what this library already does where a taxonomy is coarser than ours:
    # Snapchat's `SIGN_UP` carries both `lead` and `complete_registration`.
    #
    # The distinction survives where it matters. `purchase` remains
    # `CompletePayment`, so a funnel that books and then attends still reports
    # two different events, which is the pair an advertiser optimises between.
    schedule: "SubmitForm"
  }

  @impl true
  def name, do: :tiktok

  @impl true
  def fields do
    [
      %{
        key: :pixel_code,
        label: "Pixel code",
        placeholder: "CXXXXXXXXXXXXXXXXXXX",
        hint: "Events Manager -> your pixel -> Settings. Pasting the ttq.load snippet works too."
      },
      %{
        key: :access_token,
        label: "Access token",
        secret: true,
        hint: "Events Manager -> your pixel -> Settings -> Generate access token."
      }
    ]
  end

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :ttclid

  @impl true
  def configured?(%{pixel_code: pixel, access_token: token}),
    do: present?(pixel) and present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    body = %{
      event_source: "web",
      event_source_id: credentials.pixel_code,
      data: [event(event_name, conversion)]
    }

    HTTP.post(:tiktok, @endpoint, body,
      headers: [{"access-token", credentials.access_token}],
      success: &success?/1
    )
  end

  # `{"code": 0}` is the only success. Anything else is a rejection wearing a
  # 200.
  defp success?(%{status: status, body: %{"code" => 0}}) when status in 200..299, do: true
  defp success?(_), do: false

  defp event(event_name, conversion) do
    Hash.compact(%{
      event: event_name,
      event_time: conversion.event_time,
      event_id: conversion.event_id,
      user: user(conversion[:user_data] || %{}),
      properties: Hash.compact(conversion[:custom_data] || %{}),
      page: page(conversion[:event_source_url])
    })
  end

  # TikTok takes hashed match keys as plain strings, not arrays — the opposite
  # of Meta.
  defp user(ud) do
    Hash.compact(%{
      email: Hash.email(ud[:email]),
      phone: Hash.phone_e164(ud[:phone]),
      external_id: Hash.text(ud[:external_id]),
      ip: ud[:ip],
      user_agent: ud[:user_agent],
      ttclid: ud[:ttclid],
      ttp: ud[:ttp]
    })
  end

  defp page(nil), do: nil
  defp page(url), do: %{url: url}

  defp present?(v), do: is_binary(v) and v != ""
end
