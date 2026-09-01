defmodule Pixelex.Attribution do
  @moduledoc """
  Where a visitor came from, worked out rather than declared.

  The premise: a marketer should not have to tag anything. Ad platforms already
  stamp a click id on every click they sell, browsers already send a referrer,
  and between the two almost every visit can be attributed without a single
  `utm_source`. UTM parameters are still read when present — they are an
  explicit statement of intent and beat inference — but they are an override,
  not the mechanism.

  ## Resolution order

  1. **A paid click id** (`fbclid`, `gclid`, `ttclid`, …). Highest confidence:
     the platform stamped it, so somebody was charged for this visit.
     See `Pixelex.Attribution.ClickIds`.
  2. **Explicit campaign parameters** — `utm_*`, or Plausible's short `ref`.
     Deliberately below click ids: a stale `utm_source` copied into a link is
     common, a forged `gclid` is not.
  3. **The referrer**, classified by `ref_inspector` into search / social /
     email / paid / referral, with the search term when the engine leaks it.
  4. **Direct** — nothing to go on.

  A referrer from the site's own domain is not a referral; it is someone
  clicking around. Pass `:hostname` so those resolve to `:internal` and leave
  the visitor's real first touch intact.

  ## First touch and last touch

  Both are kept. Last touch answers "what closed this", first touch answers
  "what found them", and a library that stores only one has picked a side of an
  argument that is not its to settle. `merge/2` is the rule: first touch is
  written once and never overwritten, last touch is overwritten by any new
  non-direct touch — a direct visit does not erase the campaign that earned it.

  ## Degrading without `ref_inspector`

  `ref_inspector` is an optional dependency, so referrer classification falls
  back to the referring hostname as the source with medium `"referral"`. Click
  ids, UTM parameters, and self-referral detection all still work; only search
  vs. social vs. email gets coarser. `Pixelex.Attribution.classifier/0` reports
  which mode is active.
  """

  alias Pixelex.Attribution.ClickIds

  @ref_inspector? Code.ensure_loaded?(RefInspector)

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  @type t :: %__MODULE__{
          network: String.t() | nil,
          medium: String.t() | nil,
          source: String.t() | nil,
          campaign: String.t() | nil,
          term: String.t() | nil,
          content: String.t() | nil,
          click_id: String.t() | nil,
          click_id_param: String.t() | nil,
          referrer: String.t() | nil
        }

  defstruct network: nil,
            medium: nil,
            source: nil,
            campaign: nil,
            term: nil,
            content: nil,
            click_id: nil,
            click_id_param: nil,
            referrer: nil

  @doc "`:ref_inspector` when the classifier is available, `:hostname` when degraded."
  @spec classifier() :: :ref_inspector | :hostname
  def classifier, do: if(@ref_inspector?, do: :ref_inspector, else: :hostname)

  @doc """
  Resolve one touch from a landing URL and a referrer.

  ## Options

    * `:hostname` — the site's own host, so self-referrals are recognised.

  ## Examples

      iex> t = Pixelex.Attribution.touch("https://shop.test/x?fbclid=IwAR9", nil)
      iex> {t.network, t.medium, t.click_id}
      {"facebook", "paid_social", "IwAR9"}

      iex> t = Pixelex.Attribution.touch("https://shop.test/x", nil)
      iex> {t.source, t.medium}
      {"direct", "none"}
  """
  @spec touch(String.t() | nil, String.t() | nil, keyword()) :: t()
  def touch(url, referrer, opts \\ []) do
    query = query_params(url)
    referrer = presence(referrer)

    base =
      cond do
        click = ClickIds.detect(query) -> from_click_id(click)
        utm = from_utm(query) -> utm
        true -> from_referrer(referrer, opts[:hostname])
      end

    # Campaign detail rides along even when a click id decided the source: a
    # `gclid` says who was paid, `utm_campaign` says which campaign, and both
    # are usually on the same URL.
    %{
      base
      | campaign: base.campaign || presence(query["utm_campaign"]),
        term: base.term || presence(query["utm_term"]),
        content: base.content || presence(query["utm_content"]),
        referrer: referrer
    }
  end

  @doc """
  Fold a new touch into a stored `%{"first" => …, "last" => …}` map.

  First touch is immutable. Last touch is replaced by any touch that is not
  direct — a visitor returning by typing the URL should not wipe out the ad
  that brought them yesterday.
  """
  @spec merge(map() | nil, t()) :: map()
  def merge(existing, %__MODULE__{} = touch) do
    existing = existing || %{}
    encoded = to_map(touch)

    %{
      "first" => Map.get(existing, "first") || encoded,
      "last" => if(direct?(touch), do: Map.get(existing, "last") || encoded, else: encoded)
    }
  end

  @doc "Is this touch attributable to nothing at all?"
  @spec direct?(t()) :: boolean()
  def direct?(%__MODULE__{medium: medium}), do: medium in ["none", "internal"]

  @doc "Struct to a JSON-safe map, dropping empty fields."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = t) do
    t
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  # --- resolution -----------------------------------------------------------

  defp from_click_id({param, value, network, medium}) do
    %__MODULE__{
      network: network,
      medium: medium,
      source: network,
      click_id: value,
      click_id_param: param
    }
  end

  defp from_utm(query) do
    if Enum.any?(@utm_params, &presence(query[&1])) or presence(query["ref"]) do
      source = presence(query["utm_source"]) || presence(query["ref"])

      %__MODULE__{
        source: source,
        network: source,
        medium: presence(query["utm_medium"]) || "referral",
        campaign: presence(query["utm_campaign"]),
        term: presence(query["utm_term"]),
        content: presence(query["utm_content"])
      }
    end
  end

  defp from_referrer(nil, _own_host), do: %__MODULE__{source: "direct", medium: "none"}

  defp from_referrer(referrer, own_host) do
    host = host_of(referrer)

    cond do
      is_nil(host) ->
        %__MODULE__{source: "direct", medium: "none"}

      own_host && same_site?(host, own_host) ->
        # Not a referral. Reporting it as one is how a site ends up believing
        # its biggest traffic source is itself.
        %__MODULE__{source: "internal", medium: "internal"}

      true ->
        classify(referrer, host)
    end
  end

  if @ref_inspector? do
    defp classify(referrer, host) do
      case RefInspector.parse(referrer) do
        %RefInspector.Result{medium: :unknown} ->
          %__MODULE__{source: host, medium: "referral"}

        %RefInspector.Result{medium: medium, source: source, term: term} ->
          %__MODULE__{
            source: to_source(source, host),
            network: to_source(source, host),
            medium: to_medium(medium),
            term: term_or_nil(term)
          }
      end
    rescue
      # A missing database makes RefInspector raise rather than return unknown.
      # A referrer we cannot classify is still a referrer.
      _ -> %__MODULE__{source: host, medium: "referral"}
    end

    defp to_source(source, _host) when is_binary(source) and source != "", do: source
    defp to_source(_, host), do: host

    # RefInspector returns a STRING for a classified referrer ("search",
    # "social", "email", "paid") and the ATOM :unknown for everything else.
    # Matching only on atoms silently sent every organic Google visit to the
    # "referral" bucket, which is a wrong number rather than a crash — the kind
    # of bug that survives to production. Verified against the real database.
    defp to_medium(m) when m in ["search", :search], do: "organic_search"
    defp to_medium(m) when m in ["social", :social], do: "social"
    defp to_medium(m) when m in ["email", :email], do: "email"
    defp to_medium(m) when m in ["paid", :paid], do: "paid"
    defp to_medium(m) when is_binary(m) and m != "", do: m
    defp to_medium(_), do: "referral"

    defp term_or_nil(term) when is_binary(term) and term != "", do: term
    defp term_or_nil(_), do: nil
  else
    defp classify(_referrer, host), do: %__MODULE__{source: host, medium: "referral"}
  end

  # --- parsing --------------------------------------------------------------

  defp query_params(nil), do: %{}

  defp query_params(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} -> %{}
      %URI{query: q} -> URI.decode_query(q)
    end
  rescue
    _ -> %{}
  end

  defp query_params(_), do: %{}

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # www.shop.test and shop.test are the same site; app.shop.test is too. A full
  # public-suffix lookup would be more precise, and would also be another
  # dependency with another downloaded database — suffix matching on the
  # configured host covers the case that actually occurs.
  defp same_site?(host, own_host) do
    own = String.downcase(own_host)
    host == own or String.ends_with?(host, "." <> own) or String.ends_with?(own, "." <> host)
  end

  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp presence(_), do: nil
end
