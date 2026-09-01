defmodule Pixelex.Attribution.ClickIds do
  @moduledoc """
  The query parameters ad platforms append to a destination URL, and what each
  one means.

  This table is the reason pixelex can answer "where did this person come from"
  without anyone configuring a UTM tag. An ad platform already stamps its own
  identifier on every click it sells; reading it is strictly more reliable than
  asking a marketer to hand-build `utm_source` on every creative, because the
  platform cannot forget and cannot typo.

  It is also the only piece of reference data pixelex maintains itself.
  Referrer classification is `ref_inspector`'s job and user agents are
  `ua_inspector`'s, both actively maintained with databases updated daily. No
  such database exists for click ids, so this is forty lines of table — small
  enough to own, and the part that changes when a network launches a new one.

  ## The click id is not just a source label

  It is the join key for a server-side conversion. Meta will only match an
  offline `Purchase` back to the ad that paid for it if the event carries
  `fbc`, built from the `fbclid` captured at the click. Same for TikTok's
  `ttclid` and Snap's `sccid`. So this table feeds two things: the attribution
  report, and `Pixelex.Destinations`.
  """

  # {param, network, medium}. Order matters only for documentation; lookup is
  # by key. Case is preserved because Snap really does use both `sccid` and
  # `ScCid` depending on the placement.
  @click_ids %{
    # Meta
    "fbclid" => {"facebook", "paid_social"},
    # Google Ads. gclid is the classic one; gbraid/wbraid replaced it for
    # iOS 14.5+ traffic when ATT broke cross-app identifiers, dclid is Display
    # & Video 360, gad_source marks the surface the click came from.
    "gclid" => {"google", "paid_search"},
    "gbraid" => {"google", "paid_search"},
    "wbraid" => {"google", "paid_search"},
    "dclid" => {"google", "display"},
    "gad_source" => {"google", "paid_search"},
    "gclsrc" => {"google", "paid_search"},
    # Microsoft
    "msclkid" => {"bing", "paid_search"},
    # TikTok
    "ttclid" => {"tiktok", "paid_social"},
    # X / Twitter
    "twclid" => {"x", "paid_social"},
    # LinkedIn
    "li_fat_id" => {"linkedin", "paid_social"},
    # Pinterest
    "epik" => {"pinterest", "paid_social"},
    # Snapchat
    "sccid" => {"snapchat", "paid_social"},
    "ScCid" => {"snapchat", "paid_social"},
    # Reddit
    "rdt_cid" => {"reddit", "paid_social"},
    # Yandex
    "yclid" => {"yandex", "paid_search"},
    "ysclid" => {"yandex", "paid_search"},
    # Amazon Ads
    "aclk" => {"amazon", "display"},
    # Criteo / Outbrain / Taboola
    "cto_pld" => {"criteo", "display"},
    "obOrigUrl" => {"outbrain", "native"},
    "tblci" => {"taboola", "native"},
    # Impact / affiliate
    "irclickid" => {"impact", "affiliate"},
    # Klaviyo / email platforms that stamp a click id
    "_kx" => {"klaviyo", "email"},
    # Instagram's share id. Not an ad click, but it is the only signal that a
    # visit came out of the Instagram app rather than a browser, and without it
    # that traffic reads as direct.
    "igshid" => {"instagram", "social"},
    # Google's paid-search keyword id, used by Shopping and some legacy setups.
    "s_kwcid" => {"google", "paid_search"}
  }

  @params Map.keys(@click_ids)

  @doc "Every recognised click-id parameter name."
  @spec params() :: [String.t()]
  def params, do: @params

  @doc "The whole table, as `%{param => {network, medium}}`."
  @spec all() :: %{String.t() => {String.t(), String.t()}}
  def all, do: @click_ids

  @doc """
  The first recognised click id in a decoded query map.

  Returns `{param, value, network, medium}` or `nil`. When a URL carries more
  than one — a Google click landing on a page whose link still has an old
  `fbclid` — the paid-search and paid-social ids are preferred over the softer
  social and native ones, because that is the click someone was actually
  charged for.
  """
  @spec detect(map()) :: {String.t(), String.t(), String.t(), String.t()} | nil
  def detect(params) when is_map(params) do
    params
    |> Enum.flat_map(fn
      {key, value} when is_binary(value) and value != "" ->
        case Map.fetch(@click_ids, key) do
          {:ok, {network, medium}} -> [{key, value, network, medium}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.min_by(fn {_k, _v, _n, medium} -> priority(medium) end, fn -> nil end)
  end

  def detect(_), do: nil

  defp priority("paid_search"), do: 0
  defp priority("paid_social"), do: 1
  defp priority("display"), do: 2
  defp priority("affiliate"), do: 3
  defp priority("native"), do: 4
  defp priority("email"), do: 5
  defp priority(_), do: 6
end
