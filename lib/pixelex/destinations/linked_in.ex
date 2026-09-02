defmodule Pixelex.Destinations.LinkedIn do
  @moduledoc """
  LinkedIn Conversions API.

  Structurally unlike the others, in a way that shapes how you configure it:
  **there is no event name on the wire.** The event type lives on a *conversion
  rule* created ahead of time, and the event references it by URN. So one rule
  per event type, and the mapping has to be stored.

  ## Credentials

      %{
        access_token: "…",
        conversions: %{
          "PURCHASE" => "urn:lla:llaPartnerConversion:123",
          "LEAD"     => "urn:lla:llaPartnerConversion:456"
        }
      }

  Keys are LinkedIn rule types; `event_name/1` returns the type, and this looks
  the URN up. An event whose type has no rule is skipped rather than guessed —
  the alternative is attributing a purchase to whichever rule happened to be
  first.

  Rules are created with `POST /rest/conversions` (`conversionMethod:
  "CONVERSIONS_API"`) and must be associated with campaigns, or nothing is
  attributed. Advertisers can generate a non-expiring token directly in
  Campaign Manager → Data → Signals Manager → Direct API, with no developer app
  and no approval.

  ## Three things that differ from every other platform here

  **Success is `201`, not `200`.**

  **`userIds` must be present even when empty.** Identifying a user only
  through `userInfo` still requires `"userIds": []`, or the API answers 422.

  **No phone number field exists.** `SHA256_EMAIL`, IP, the LinkedIn click id
  and Google's advertising id are the whole match-key vocabulary.

  ## Version pinning

  `Linkedin-Version` is a required `YYYYMM` header, not a path segment.
  Defaults to `#{Application.compile_env(:pixelex, :linkedin_version, "202608")}`;
  override with `config :pixelex, linkedin_version: "202610"`. Versions are
  supported for at least a year, and a missing or expired one is an error
  rather than a fallback.
  """
  @behaviour Pixelex.Destination

  alias Pixelex.Destinations.{Hash, HTTP}

  @endpoint "https://api.linkedin.com/rest/conversionEvents"
  @default_version "202608"

  @events %{
    page_view: "KEY_PAGE_VIEW",
    view_content: "VIEW_CONTENT",
    search: "SEARCH",
    add_to_cart: "ADD_TO_CART",
    initiate_checkout: "START_CHECKOUT",
    add_payment_info: "ADD_BILLING_INFO",
    purchase: "PURCHASE",
    lead: "LEAD",
    complete_registration: "SIGN_UP",
    subscribe: "SUBSCRIBE",
    contact: "CONTACT",
    schedule: "SCHEDULE"
  }

  @impl true
  def name, do: :linkedin

  @impl true
  def fields do
    [
      %{
        key: :access_token,
        label: "Access token",
        secret: true,
        hint: "LinkedIn Marketing API OAuth token with r_ads_conversions."
      },
      %{
        key: :conversions,
        label: "Conversion rules",
        type: :map,
        hint: ~s|One per line, canonical_event=conversion_id, e.g. purchase=12345678|
      },
      %{
        key: :partner_id,
        label: "Partner ID (browser pixel)",
        optional: true,
        placeholder: "1234567",
        hint: "Campaign Manager -> Insight Tag. Only the browser pixel uses it."
      }
    ]
  end

  @impl true
  def event_name(canonical), do: @events[canonical]

  @impl true
  def click_id_key, do: :li_fat_id

  @impl true
  def configured?(%{access_token: token, conversions: conversions})
      when is_map(conversions) and map_size(conversions) > 0,
      do: present?(token)

  def configured?(_), do: false

  @impl true
  def deliver(credentials, event_type, conversion) do
    case conversion_urn(credentials, event_type) do
      nil ->
        # No rule for this event type. Skipping is correct: attributing it to
        # some other rule would put purchases in the leads report.
        :ok

      urn ->
        HTTP.post(:linkedin, @endpoint, event(urn, conversion),
          headers: [
            {"authorization", "Bearer " <> credentials.access_token},
            {"x-restli-protocol-version", "2.0.0"},
            {"linkedin-version", version()}
          ],
          success: &success?/1
        )
    end
  end

  # 201 Created, for both the single and batch forms.
  defp success?(%{status: status}), do: status in 200..299

  defp event(urn, conversion) do
    Hash.compact(%{
      conversion: urn,
      # Milliseconds, and rejected outright if more than 90 days old.
      conversionHappenedAt: conversion.event_time * 1_000,
      eventId: conversion.event_id,
      conversionValue: conversion_value(conversion[:custom_data] || %{}),
      user: user(conversion[:user_data] || %{})
    })
  end

  defp conversion_value(custom) do
    amount = custom[:value] || custom["value"]
    currency = custom[:currency] || custom["currency"]

    if amount && currency do
      # A decimal STRING, not a number.
      %{currencyCode: currency, amount: to_string(amount)}
    end
  end

  defp user(ud) do
    ids =
      [
        id("SHA256_EMAIL", Hash.email(ud[:email])),
        id("LINKEDIN_FIRST_PARTY_ADS_TRACKING_UUID", ud[:li_fat_id]),
        id("PLAINTEXT_IP_ADDRESS", ipv4(ud[:ip])),
        id("GOOGLE_AID", ud[:aaid])
      ]
      |> Enum.reject(&is_nil/1)

    info =
      Hash.compact(%{
        firstName: ud[:first_name],
        lastName: ud[:last_name],
        companyName: ud[:company],
        title: ud[:title],
        countryCode: ud[:country]
      })

    # userIds is always present, even empty. Omitting it is a 422 —
    # "field is required but not found and has no default value".
    %{userIds: ids}
    |> maybe_put(:userInfo, if(info[:firstName] && info[:lastName], do: info))
    |> maybe_put(:externalIds, external_ids(ud[:external_id]))
  end

  defp id(_type, nil), do: nil
  defp id(_type, ""), do: nil
  defp id(type, value), do: %{idType: type, idValue: value}

  # LinkedIn accepts IPv4 only; an IPv6 address is rejected rather than ignored.
  defp ipv4(ip) when is_binary(ip) do
    if ip =~ ~r/^\d{1,3}(\.\d{1,3}){3}$/, do: ip
  end

  defp ipv4(_), do: nil

  # Documented maximum size 1; further values are silently ignored, so send one.
  defp external_ids(nil), do: nil
  defp external_ids(""), do: nil
  defp external_ids(id), do: [to_string(id)]

  defp conversion_urn(credentials, event_type) do
    conversions = credentials[:conversions] || %{}
    conversions[event_type] || conversions[to_string(event_type)]
  end

  defp version, do: Application.get_env(:pixelex, :linkedin_version, @default_version)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(v), do: is_binary(v) and v != ""
end
