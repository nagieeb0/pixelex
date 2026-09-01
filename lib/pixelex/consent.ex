defmodule Pixelex.Consent do
  @moduledoc """
  Whether this visitor may be tracked at all, and by which layer.

  Two questions that get conflated and must not be:

    * **first-party analytics** — a cookieless, rotating-hash pageview stored in
      the site's own database. Nothing is written to or read from the device, so
      ePrivacy Article 5(3) — the *cookie* rule — is not engaged, and no banner
      is required for it. GDPR still governs the processing; the lawful basis is
      legitimate interest under Article 6(1)(f), available precisely because the
      data is not collected for advertising.
    * **ad-platform destinations** — Meta, TikTok, Snap, Google. These send
      identifying data to a third party for advertising. That needs consent
      where consent law applies, and suppressing only the *browser* pixel while
      the server-side Conversions API keeps firing is theatre: the server leg
      carries **more** identifying data (hashed email, phone, IP) to the same
      companies.

  `allow?/2` answers the first. `destinations_allowed?/1` answers the second.
  They are separate because answering them together is how a site ends up
  either over-collecting or throwing away its own analytics for no legal gain.

  ## Where consent is required

  The EEA, the UK and Switzerland. Not everywhere: gating a visitor in Egypt or
  the Gulf costs real attribution data and buys nothing, because ePrivacy
  consent rules do not reach them. `required?/1` is the list.

  ## Global Privacy Control

  `Sec-GPC: 1` is honoured by default and is checked **server-side**, from the
  header. It is a legally binding opt-out under CCPA/CPRA and a growing set of
  US state laws — unlike DNT, which never had legal force, was ignored, and was
  removed from Safari. DNT is off by default and available as a courtesy.

  Checked server-side for two reasons: the client cannot be trusted to check a
  signal about itself, and an ad-blocker may well have removed the script that
  would have.

  ## It ships off

  `consent_gate: [enabled: true]` turns the geographic gate on. The default is
  off, because switching it on before a banner exists silently stops tracking
  for those visitors, and the honest default is current behaviour until the
  decision is deliberate.
  """

  alias Pixelex.Config

  # EEA (EU 27 + Iceland, Liechtenstein, Norway) + UK + Switzerland.
  @gated ~w(
    AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE
    IS LI NO
    GB CH
  )

  @typedoc """
  A visitor's signals, as the plug layer extracts them.

    * `:country` — ISO-3166-1 alpha-2, from geo lookup or a CDN header
    * `:decision` — `"granted"` / `"denied"` / `nil`, from the host's banner
    * `:gpc` — the `Sec-GPC` header value
    * `:dnt` — the `DNT` header value
  """
  @type signals :: %{
          optional(:country) => String.t() | nil,
          optional(:decision) => String.t() | nil,
          optional(:gpc) => String.t() | nil,
          optional(:dnt) => String.t() | nil
        }

  @doc "The countries where a consent decision is legally required."
  @spec gated_countries() :: [String.t()]
  def gated_countries, do: @gated

  @doc "Is a consent decision required for this visitor's country?"
  @spec required?(String.t() | nil) :: boolean()
  def required?(country) do
    gate_enabled?() and is_binary(country) and String.upcase(country) in @gated
  end

  @doc """
  Should a banner be shown? Only when a decision is required and none has been
  made. `nil` and `"denied"` both block; opt-in, not opt-out.
  """
  @spec prompt?(String.t() | nil, String.t() | nil) :: boolean()
  def prompt?(country, decision) do
    required?(country) and decision not in ["granted", "denied"]
  end

  @doc """
  May pixelex record a first-party event for this visitor?

  Returns `true`, or `{:denied, reason}` so the caller can report *why* nothing
  was recorded. A silent `false` here is indistinguishable from a bug.
  """
  @spec allow?(signals()) :: true | {:denied, :gpc | :dnt | :no_consent}
  def allow?(signals) when is_map(signals) do
    cond do
      Config.honor_gpc?() and opted_out?(signals[:gpc]) -> {:denied, :gpc}
      Config.honor_dnt?() and opted_out?(signals[:dnt]) -> {:denied, :dnt}
      not consented?(signals) -> {:denied, :no_consent}
      true -> true
    end
  end

  @doc """
  May pixelex forward this event to third-party ad platforms?

  Strictly narrower than `allow?/1`: a first-party pageview can be lawful where
  a Conversions API call is not.
  """
  @spec destinations_allowed?(signals()) :: true | {:denied, atom()}
  def destinations_allowed?(signals) when is_map(signals) do
    with true <- allow?(signals) do
      # Outside the gated countries there is no consent requirement, so an
      # absent decision is not a refusal. Inside, only an explicit grant counts.
      if required?(signals[:country]) and signals[:decision] != "granted" do
        {:denied, :no_consent}
      else
        true
      end
    end
  end

  @doc """
  Whether tracking is permitted, as a plain boolean.

  For call sites that only branch and have nowhere useful to put the reason.
  """
  @spec allowed?(signals()) :: boolean()
  def allowed?(signals), do: allow?(signals) == true

  # A missing country means the caller could not determine one — an admin
  # action, a cron, a server-side call with no visitor. Those are not subject to
  # a banner, so an unknown country is not treated as a gated one.
  defp consented?(signals) do
    country = signals[:country]

    not required?(country) or signals[:decision] == "granted"
  end

  # "1" is the spec'd value for both headers. Anything else — including "0" and
  # the absent case — is not an opt-out.
  defp opted_out?("1"), do: true
  defp opted_out?(true), do: true
  defp opted_out?(_), do: false

  defp gate_enabled?, do: Application.get_env(:pixelex, :consent_gate, [])[:enabled] == true
end
