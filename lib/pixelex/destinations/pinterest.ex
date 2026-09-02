defmodule Pixelex.Destinations.Pinterest do
  @moduledoc """
  Pinterest Conversions API (REST v5).

  ## Credentials

      %{ad_account_id: "5493…", access_token: "pina_…"}

  The token comes from Ads Manager → Ad Account Overview → Conversions →
  Conversions API. The **ad account is the scope** — there is no pixel id in
  the path, unlike every other platform here.

  ## Two traps, both silent

  **Purchase is `checkout`.** Pinterest's enum has no `purchase`. Sending one
  returns an explicit rejection — the only platform here that says so out loud
  — but only in the per-event status array, not the HTTP code.

  **A 200 does not mean the events landed.** Pinterest answers 200 with
  `num_events_received` / `num_events_processed` and a per-event status list.
  A batch with one bad event is a 200 with `"status": "failed"` buried in the
  body. This client reads that array.

  ## Click id

  `user_data.click_id`, from the `_epik` cookie or the `&epik=` query
  parameter. Pinterest prefers the cookie: the query parameter is frequently
  stripped in transit.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @endpoint "https://api.pinterest.com/v5/ad_accounts"

  @events %{
    page_view: "page_visit",
    view_content: "view_content",
    search: "search",
    add_to_cart: "add_to_cart",
    initiate_checkout: "initiate_checkout",
    add_payment_info: "add_payment_info",
    # NOT "purchase" — Pinterest's enum does not contain it.
    purchase: "checkout",
    lead: "lead",
    complete_registration: "signup",
    subscribe: "subscribe",
    contact: "contact",
    schedule: "schedule"
  }

  @impl true
  def name, do: :pinterest

  @impl true
  def fields do
    [
      %{
        key: :ad_account_id,
        label: "Ad account ID",
        placeholder: "549755885175",
        hint: "Ads Manager -> the account switcher. This is the AD ACCOUNT id, not the tag id."
      },
      %{
        key: :access_token,
        label: "Access token",
        secret: true,
        hint: "developers.pinterest.com -> your app -> access token."
      }
    ]
  end

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :epik

  @impl true
  def configured?(%{ad_account_id: account, access_token: token}),
    do: present?(account) and present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_name, conversion) do
    url = "#{@endpoint}/#{credentials.ad_account_id}/events"

    HTTP.post(:pinterest, url, %{data: [event(event_name, conversion)]},
      headers: [{"authorization", "Bearer " <> credentials.access_token}],
      success: &success?/1
    )
  end

  # 200 is necessary and not sufficient. The per-event array is where a
  # rejection actually appears.
  defp success?(%{status: status, body: body}) when status in 200..299 do
    case body do
      %{"events" => events} when is_list(events) ->
        Enum.all?(events, &(Map.get(&1, "status") != "failed"))

      %{"num_events_received" => received, "num_events_processed" => processed} ->
        received == processed

      _ ->
        true
    end
  end

  defp success?(_), do: false

  defp event(event_name, conversion) do
    Hash.compact(%{
      event_name: event_name,
      action_source: conversion[:action_source] || "web",
      event_time: conversion.event_time,
      event_id: conversion.event_id,
      event_source_url: conversion[:event_source_url],
      user_data: user_data(conversion[:user_data] || %{}),
      custom_data: custom_data(conversion[:custom_data] || %{})
    })
  end

  # Hashed match keys are arrays, like Meta's. Phone is digits only with no
  # leading plus — the opposite of Reddit's and TikTok's rule.
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
      click_id: ud[:epik] || ud[:click_id]
    })
  end

  # Pinterest wants `value` as a STRING it parses to a double, while every
  # other platform here wants a number.
  defp custom_data(custom) do
    custom
    |> Hash.compact()
    |> then(fn data ->
      case data[:value] || data["value"] do
        nil -> data
        value -> Map.put(data, :value, to_string(value))
      end
    end)
    |> Map.drop(["value"])
  end

  defp wrap(nil), do: nil
  defp wrap(value), do: [value]

  defp present?(v), do: is_binary(v) and v != ""
end
