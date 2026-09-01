defmodule Pixelex.Pipeline do
  @moduledoc """
  One event, from a request context to the ingest buffer.

      consent → bot filter → enrich → attribute → sessionise → validate → buffer

  Every stage can drop the event and none of them can raise into the caller.
  That is not defensive style for its own sake: every call site is a page load,
  a booking, or a payment, and analytics is never allowed to be the reason one
  of those fails.

  Each drop is counted under `[:pixelex, :pipeline, :drop]` with a reason, so
  "we are recording nothing" is a number on a dashboard rather than a discovery
  made three weeks later.

  ## The context

  A plain map, built by `Pixelex.Plug`, `Pixelex.LiveView`, or the host:

      %{
        site_id:    "shop",            # required
        ip:         "197.55.10.3",
        user_agent: "Mozilla/5.0 …",
        url:        "https://shop.test/pricing?gclid=Cj0",
        referrer:   "https://www.google.com/",
        hostname:   "shop.test",       # the site's own host, for self-referrals
        country:    "EG", region: nil, city: nil,
        user_id:    "user-uuid",       # when signed in
        render:     :dead | :connected | :client | :server,
        consent:    %{decision: "granted", gpc: nil, dnt: nil}
      }
  """
  require Logger

  alias Pixelex.{Attribution, Config, Consent, Enrich, Event, Ingest, Sessions}

  @pageview "px.pageview"

  @browser_renders [:client, :dead, :connected]

  @type context :: map()
  @type result :: :ok | {:dropped, atom()}

  @doc "The reserved name pixelex uses for a page view."
  def pageview_name, do: @pageview

  @doc """
  Run one event through the pipeline.

  Returns `:ok` when it reaches the buffer, or `{:dropped, reason}`. Never
  raises.
  """
  @spec run(context(), String.t() | atom(), map()) :: result()
  def run(context, name, props \\ %{}) do
    context = normalise(context)

    with :ok <- check_consent(context),
         {:ok, device} <- check_bot(context),
         {:ok, event} <- build(context, name, props, device) do
      Ingest.push(event)
      :ok
    else
      {:dropped, reason} -> drop(reason, context)
    end
  rescue
    e ->
      Logger.warning("Pixelex.Pipeline crashed, event dropped: #{inspect(e)}")
      drop(:exception, %{})
  end

  # --- stages ---------------------------------------------------------------

  defp check_consent(context) do
    case Consent.allow?(context.consent) do
      true -> :ok
      {:denied, reason} -> {:dropped, reason}
    end
  end

  # Only browser-originated events are bot-filtered. A server-side
  # `Pixelex.track/3` was called deliberately by the host, and a mobile SDK
  # sends an HTTP-library user agent that this check would otherwise reject.
  defp check_bot(%{render: render, user_agent: ua}) when render in @browser_renders do
    case Enrich.device(ua) do
      %{bot?: true} -> {:dropped, :bot}
      device -> {:ok, device}
    end
  end

  defp check_bot(%{user_agent: ua}), do: {:ok, Enrich.device(ua)}

  defp build(context, name, props, device) do
    parts = Enrich.url_parts(context.url)

    touch =
      Attribution.touch(context.url, context.referrer,
        hostname: context.hostname || parts.hostname
      )

    session = Sessions.resolve(context.site_id, context.user_agent, context.ip, touch)

    attrs = %{
      site_id: context.site_id,
      name: name,
      client_ts: context.client_ts,
      visitor_id: session.visitor_id,
      session_id: session.session_id,
      user_id: context.user_id,
      url: parts.url,
      pathname: parts.pathname,
      hostname: parts.hostname,
      referrer: context.referrer,
      attribution: session.attribution,
      country: context.country,
      region: context.region,
      city: context.city,
      browser: device.browser,
      os: device.os,
      device_type: device.device_type,
      render: context.render,
      props: props
    }

    cond do
      duplicate_pageview?(name, session.visitor_id, parts.pathname) ->
        {:dropped, :duplicate_pageview}

      true ->
        case Event.new(attrs) do
          {:ok, event} -> {:ok, event}
          {:error, reason} -> {:dropped, reason}
        end
    end
  end

  # Only page views are deduplicated. A custom event fired twice in a second is
  # usually two real clicks, and silently collapsing them would make the click
  # counts wrong in the harder-to-notice direction.
  defp duplicate_pageview?(name, visitor_id, pathname) do
    name in [@pageview, :"px.pageview"] and
      not Sessions.first_view?(visitor_id, pathname, Config.pageview_dedupe_ms())
  end

  # --- helpers --------------------------------------------------------------

  defp normalise(context) do
    %{
      site_id: context[:site_id] || context["site_id"],
      ip: context[:ip],
      user_agent: context[:user_agent],
      url: context[:url],
      referrer: context[:referrer],
      hostname: context[:hostname],
      country: context[:country],
      region: context[:region],
      city: context[:city],
      user_id: context[:user_id],
      client_ts: context[:client_ts],
      render: context[:render] || :server,
      consent: context[:consent] || %{}
    }
  end

  defp drop(reason, context) do
    :telemetry.execute([:pixelex, :pipeline, :drop], %{count: 1}, %{
      reason: reason,
      site_id: context[:site_id]
    })

    {:dropped, reason}
  end
end
