# pixelex

Cookieless, multi-tenant, first-party analytics for Phoenix. Web visitors,
product events and ad-platform attribution over **one event log**, in your own
Postgres.

[![Hex.pm](https://img.shields.io/hexpm/v/pixelex.svg)](https://hex.pm/packages/pixelex)
[![Docs](https://img.shields.io/badge/hex-docs-8e7cc3.svg)](https://hexdocs.pm/pixelex)
[![CI](https://github.com/nagieeb0/pixelex/actions/workflows/ci.yml/badge.svg)](https://github.com/nagieeb0/pixelex/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/pixelex.svg)](https://github.com/nagieeb0/pixelex/blob/main/LICENSE)

> **0.4.0** — interaction discovery, depth and engagement reporting, and
> autosaving settings. Early;
> the API may still move before 1.0.

```elixir
# It counts page views with no JavaScript at all.
plug Pixelex.Plug

# It knows where a visitor came from without a single UTM tag.
Pixelex.Attribution.touch("https://shop.test/?gclid=Cj0KCQ", nil)
#=> %Pixelex.Attribution{network: "google", medium: "paid_search", click_id: "Cj0KCQ"}

# And it identifies visitors without storing anything on their device.
Pixelex.track(context, "booking_completed", %{value: 1499.0, currency: "EGP"})
```

## Why this exists

Nothing in the Elixir ecosystem does this. `phoenix_analytics` logs requests
and has no visitor identity, no sessions and no product analytics. Plausible is
AGPL-3.0, a standalone application and a ClickHouse dependency — not something
you can put in `mix.exs`. Nothing on Hex does funnels, retention or cohorts;
[Plausible CE withholds funnels as a paid feature](https://plausible.io/blog/community-edition).
Nothing on Hex does ad-platform Conversions API dispatch at all — and nothing
lets a tenant set their own pixels up from a screen instead of a deploy.

## Three ideas

**One event, three products.** Web analytics, product analytics and ad
attribution differ in volume, identity model and destination, but they are all
views over the same log. Get `Pixelex.Event` right and the three collapse into
one library.

**Server-first ingestion.** Every hosted analytics product measures from the
browser because it is not running inside your application. A library is. A
`Plug` and a LiveView `on_mount` hook count every page view — initial,
`live_patch`, `live_navigate` — with **zero client bytes and nothing for an
ad-blocker to block**. Plausible's own research found a site losing
[58% of visitors](https://plausible.io/blog/do-ad-blockers-block-plausible-analytics)
to blockers with Google Analytics. That is the number this does not have. The
JS tracker becomes an optional enrichment layer for screen size and scroll
depth, not the transport.

**Attribution you do not configure.** Ad platforms already stamp a click id on
every click they sell — `fbclid`, `gclid`, `ttclid`, [twenty-odd others](lib/pixelex/attribution/click_ids.ex)
— and browsers already send a referrer. Reading both is strictly more reliable
than asking a marketer to hand-build `utm_source` on every creative. UTM
parameters still win when present; they are an override, not the mechanism.

## Install

```bash
mix pixelex.install
```

generates the migration and prints the wiring. Or by hand:

```elixir
def deps do
  [
    {:pixelex, "~> 0.4"},

    # Optional but strongly recommended: referrer classification and
    # browser/OS/device parsing plus real bot filtering. Both Apache-2.0.
    {:ref_inspector, "~> 2.0"},
    {:ua_inspector, "~> 3.0"}
  ]
end
```

```elixir
# config/config.exs
config :pixelex,
  repo: MyApp.Repo,
  sites: %{
    "shop.test" => [allowed_events: ~w(book_click call_click order_started)]
  }
```

```elixir
# priv/repo/migrations/..._add_pixelex.exs
defmodule MyApp.Repo.Migrations.AddPixelex do
  use Ecto.Migration

  def up, do: Pixelex.Migration.up()
  def down, do: Pixelex.Migration.down()
end
```

```bash
mix ref_inspector.download
mix ua_inspector.download
```

> ⚠️ Those databases are **downloaded, not bundled** — which is what keeps
> pixelex cleanly Apache-2.0, since the underlying `referers.yml` is GPL-3.0.
> It also means your Dockerfile needs those two lines before `mix release`.

### Capture

```elixir
# endpoint.ex, after Plug.Static
plug Pixelex.Plug

# router.ex, in the :browser pipeline, after fetch_session
plug Pixelex.Plug.Session

# router.ex, for browser-sent events (only if you need them)
forward "/px", Pixelex.Plug.Ingest

# router.ex, for LiveView apps
live_session :default, on_mount: [Pixelex.LiveView] do
  live "/", HomeLive
end
```

For LiveView you also need the socket to see the request:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [
    connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]
  ]
```

Without `:peer_data` every visitor hashes to the same id and your site has one
visitor forever.

### Keep partitions ahead of the calendar

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [
    {"0 3 * * *", MyApp.PixelexMaintenance}
  ]}]
```

```elixir
defmodule MyApp.PixelexMaintenance do
  use Oban.Worker

  def perform(_job) do
    Pixelex.Partitions.ensure(2)
    Pixelex.Partitions.drop_expired()
    :ok
  end
end
```

A range-partitioned table with no partition covering today rejects every
insert. Nothing degrades gracefully — ingestion stops at midnight on the first
of the month. `ensure/1` is idempotent; run it hourly if you like.

## How identity works

```
visitor_id = base64url(first 64 bits of HMAC-SHA256(salt_of_day, site_id | ua | ip))
```

The salt rotates every UTC day and is deleted after two, so the identifier is
unlinkable across days and cannot be recomputed later even with the raw inputs.
Rotation needs no scheduler: the salts table is keyed by date, so it is
`INSERT ... ON CONFLICT DO NOTHING` and the first node to notice the new day
wins.

**The subtle part**, and the one everything else depends on: at 00:00 UTC every
visitor's hash changes, so every open session would look like a new person.
`Pixelex.Sessions.resolve/4` looks the visitor up under **yesterday's** salt too
and moves the session across. Without it, session counts spike every night and
average duration collapses, and nothing anywhere reports an error.

### The legal position, stated honestly

Nothing is stored on or read from the visitor's device, so ePrivacy Article
5(3) — the *cookie* rule — is not engaged and no banner is required for
first-party analytics. GDPR still governs the processing: the rotating hash is
pseudonymisation, destroying the salt within 24h is anonymisation, and the
lawful basis is legitimate interest under Article 6(1)(f), available precisely
because none of it is collected for advertising.

This is Plausible's published position and it
[is contested at the margin](https://github.com/plausible/analytics/discussions/1963):
while the salt lives, the hash is pseudonymous personal data, not anonymous.
pixelex does not claim to make you "GDPR compliant". It gives you the argument
and its limits.

**Forwarding to ad platforms is a separate, narrower gate.** That does need
consent where consent law applies — and suppressing only the browser pixel
while a server-side Conversions API keeps firing is theatre, because the server
leg carries *more* identifying data to the same companies. See
`Pixelex.Consent`.

### What cookieless costs you

First touch is **session-scoped**. Attributing a conversion to an ad clicked
three weeks ago requires a durable identifier on the visitor's device, and
putting one there is exactly what Article 5(3) governs. A library cannot
promise "no cookie banner" and "30-day first-touch attribution" at the same
time; anything claiming both is doing the second one unlawfully in the EEA.

Multi-day unique visitor counts are a **sum of dailies**, and therefore an
over-count, for the same reason — the hash is a different value tomorrow. No
HyperLogLog sketch fixes this; Plausible has the identical ceiling.

## Design notes

| decision | why |
|---|---|
| Plain Postgres, no extensions | `hll` is absent on Supabase; TimescaleDB is Apache-edition-only on Neon and deprecated on Supabase. A library that needs an extension is one most people cannot install. |
| Monthly range partitions from the first migration | Converting a populated table later means copying every row under an exclusive lock, on the table that grows fastest. |
| Retention by `DROP TABLE` on a partition | O(1). `DELETE ... WHERE occurred_at < …` rewrites the largest table in the system and leaves the space to vacuum. |
| Rollups by `ON CONFLICT DO UPDATE` | `REFRESH MATERIALIZED VIEW` is a full recompute every time; Postgres has no incremental materialised views. |
| UUIDv7 event ids | The first 48 bits are a timestamp, so ids sort by insertion and the primary key stops being a random-write hotspot. |
| HMAC-SHA256, not SipHash | `:crypto` is stdlib. At these volumes the speed difference is far below the cost of the write that follows. |
| Drop events under pressure | Analytics must never apply backpressure to a request. Losing events is a bad day; growing a queue until the node dies takes the application with it. |
| A rate limiter in 25 lines of ETS | The requirement is one number per IP per minute. That is `:ets.update_counter/4`. |
| `ref_inspector` / `ua_inspector` optional | They depend on `hackney ~> 1.0`, and hackney 1.25.0 carries four unpatched advisories including one HIGH, with fixes only in 4.x. Requiring them would put that in every consumer's `mix hex.audit`. |

## Reading the data

```elixir
range = Pixelex.Query.range(:last_30_days)

Pixelex.Query.Traffic.summary("shop", range)
#=> %{pageviews: 4182, sessions: 1204, visitors_daily_sum: 1103,
#=>   bounce_rate: 0.42, views_per_session: 3.47, events: 5006}

Pixelex.Query.Funnel.run("shop", range, ~w(px.pageview view_doctor book_click booking_completed))
Pixelex.Query.Retention.cohorts("shop", range, bucket: "week")
```

Also `top_pages/3`, `sources/3`, `mediums/3`, `campaigns/3`, `countries/3`,
`browsers/3`, `devices/3`, `events/3`, `timeseries/3`.

The funnel builds one CTE per step, each joined to the previous and taking only
events at or after it. The single-pass shortcut everyone reaches for —
`min(occurred_at) FILTER (WHERE name = step_n)` — silently drops anyone who did
the last step once before the funnel and again properly within it, which is any
funnel whose final step is reachable from elsewhere.

## Sending conversions back to the ad platforms

```elixir
Pixelex.Destinations.fire("shop", :purchase,
  event_id: "order:" <> order.id,          # derive it from the row
  user_data: %{email: patient.email, phone: patient.phone, click_id: fbclid},
  custom_data: %{currency: "EGP", value: 1499.0}
)
```

Meta, TikTok, Snapchat, GA4, Pinterest, Reddit and LinkedIn. Each no-ops
without its own credentials. The same `event_id` goes to the browser pixel and
to every platform, so the pair counts once — and because it is derived from the
row, a replay cannot double-count, which is what makes retrying safe. Delivery
runs through Oban with five attempts.

X is not shipped. Its endpoint and payload are known, but it needs OAuth 1.0a
signing, its own API-reference page for the conversions endpoint 404s so there
is no field-level spec, and the simpler header auth that would avoid the signer
appears only in third-party write-ups. A guessed endpoint is worse than seven
platforms.

Three things the platforms disagree on, each of which fails with a `200` and no
matches rather than an error — all handled, all tested:

| | |
|---|---|
| phone | Meta, Snapchat, Pinterest: digits only. TikTok, Reddit: E.164 with the `+`. LinkedIn: no phone field at all. |
| hashed match keys | arrays for Meta, Snapchat, Pinterest; plain strings for TikTok; `{idType, idValue}` pairs for LinkedIn. |
| success | `200` for most; `200` **with** `{"code": 0}` for TikTok; `200` with a per-event status array for Pinterest; `201` for LinkedIn. |

Reddit's email rule is also its own — lowercase, strip dots from the local
part, drop everything after a `+` — and the implementation is checked against
Reddit's published test vector.

## Setting up pixels without a deploy

`pixelex_settings` mounts a screen where a tenant pastes the snippet their ad
platform gave them. Valid ids and every field edit save automatically; **Test**
still verifies the server-side credential against the platform's live API.

```elixir
scope "/admin" do
  pipe_through [:browser, :require_admin]
  pixelex_dashboard "/analytics"
  pixelex_settings  "/analytics/settings"
end
```

Three things make it work rather than exist:

**It reads and saves the snippet.** The form does not ask a marketer whether their
platform calls it a *pixel code*, a *measurement ID* or an *ad account ID*.
Paste the whole `<script>` block and `Pixelex.Destinations.Detect` finds the id
inside it and drops it in the right box on the right card. Meta, GA4, TikTok,
Snapchat, Reddit, LinkedIn and Pinterest snippets are all recognised. Access
tokens and API secrets have no distinguishing shape, so they are the one thing
still typed — guessing at them would put a token in the wrong platform's row and
fail as a `401` three weeks later.

**Test is a real call.** Wrong credentials do not raise; they produce a silent
gap in reporting nobody notices until conversions look wrong. So the button
sends a live `page_view` through the platform's own API and prints what came
back. Meta's `test_event_code` is used when set, so it lands in Test Events
rather than in the advertiser's real numbers. Setup is not "saved", it is
verified.

**Tokens go in and do not come out.** A secret is written, never rendered — the
field shows *set* or *not set*, a blank box on save keeps the stored value, and
*Disconnect* is how you remove one. Set a key and they are encrypted at rest:

```elixir
config :pixelex, secret_key: System.get_env("PIXELEX_SECRET_KEY")
# :crypto.strong_rand_bytes(32) |> Base.encode64()
```

Turning that on is not a migration. Plaintext values keep reading and become
ciphertext the next time they are saved. If the key later goes missing, a
credential decrypts to `nil` and the platform reads as unconfigured rather than
authenticating with ciphertext forever.

The screen has **no authentication of its own** — scope it behind yours, same as
the dashboard. Unlike the dashboard it *writes*, so on a path-based multi-tenant
app pin the site rather than letting `?site=` choose it:

```elixir
pixelex_settings "/analytics/settings", site_id: "acme"
# or: on_mount: [{MyAppWeb.Analytics, :owns_site}]
```

With a custom-domain product the host *is* the tenant and the default is already
right.

### A pixel id alone is enough to start

Hosted store platforms ask a merchant for one thing: the pixel **ID**. That is
all a *browser* pixel needs — the snippet sits in the page and the browser talks
to Meta directly.

The Conversions API is the other half, and it cannot work on an id. Meta will
not accept a call from your server authenticated by a pixel id; that is what the
access token is for. So the two are not alternatives:

| | id only | id + token |
|---|---|---|
| browser pixel | ✅ | ✅ |
| Conversions API | ❌ impossible | ✅ |
| survives an ad-blocker | ❌ | ✅ |

pixelex renders the browser half for you, from the ids already in the settings
screen:

```heex
<%!-- root layout, once --%>
<Pixelex.Pixels.tags site_id={@site_id} consent={@consent} />
```

A merchant pastes a pixel id and their pixel starts firing — no deploy, no
snippet in a template, no second place to keep the id. Add the access token and
the same conversions also go server-to-server, sharing one `event_id` so nothing
counts twice. The card says which state it is in:

```
meta   [browser pixel active]
tiktok [browser + server, deduped]
snapchat [not set up]
```

Meta, TikTok, Snapchat, GA4, Reddit, Pinterest and LinkedIn. Ids go into a
`<script>`, so each is validated against `[A-Za-z0-9._-]{1,64}` first and a
platform whose id fails is skipped. `Pixelex.Consent` is honoured, and
`nonce={@csp_nonce}` lands on every inline script.

> These are the *advertiser's* pixels and they are blockable — that is why the
> server leg exists, not an argument against this one. pixelex's own analytics
> are still measured server-side with nothing for a blocker to block.

### Or in config, for one site

```elixir
config :pixelex,
  sites: %{
    "shop" => [
      allowed_events: ~w(book_click booking_completed),
      destinations: %{
        "meta" => %{"pixel_id" => "…", "access_token" => System.fetch_env!("META_TOKEN")}
      }
    ]
  }
```

Config wins over the database, so a site declared here cannot be edited from the
settings screen — which says so, rather than showing a Save button that does
nothing.

### Adding your own platform

Implement `Pixelex.Destination` and add
`c:Pixelex.Destination.fields/0`. The settings screen grows a card for it with
no further work.

## The browser tracker

Optional. Page views are already counted server-side.

```html
<script defer src="/px/pixelex.js" data-site="shop"></script>
```

About 2.3 KB gzipped, served from your own origin. It discovers visible links,
buttons, submit controls, `role="button"` elements and expandable `summary`
controls — including elements added later by LiveView — then emits:

| event | meaning |
|---|---|
| `px.inventory` | how many interactive elements, buttons and links exist on each page, plus their inferred action types |
| `px.click` | the inferred action (`booking`, `contact_whatsapp`, `contact_phone`, `submit`, `expand`, `navigate` or `interact`) |
| `px.engagement` | active time and maximum scroll depth |
| `px.pageview` | client navigation and browser enrichment |

Those four library-owned names are accepted without copying them into every
site's allowlist; invented `px.*` names are still rejected. The dashboard shows
page inventory, grouped interactions, scroll depth, engaged time and the latest
event timeline.

Automatic capture deliberately never reads `textContent`, `innerText` or input
values. For stable business vocabulary, annotate only what is useful:

```heex
<.link
  navigate={~p"/book"}
  data-track="booking_started"
  data-track-action="booking"
  data-track-label="hero_booking"
  data-track-section="hero"
>
  Book now
</.link>
```

`data-track` sends an explicit allowlisted event as before. The other
attributes enrich the automatic `px.click`; `data-track-label` is optional and
must be intentionally supplied by the host. Put `data-pixelex-ignore` on an
element or ancestor to exclude it, or `data-interactions="false"` on the script
tag to disable automatic interaction capture entirely.

The tracker also handles SPA and LiveView navigation, screen size, scroll depth
and engagement time. It guards localhost, `file://`, headless browsers, GPC and
a local opt-out. It sends with `keepalive`, falls back to an image, and fires on
`visibilitychange` and `pagehide`, **never** `unload`, which disqualifies a page
from the back-forward cache.

## Telemetry

| event | measurements | when |
|---|---|---|
| `[:pixelex, :ingest, :push]` | `%{count}` | an event is queued |
| `[:pixelex, :ingest, :flush]` | `%{count, bytes, written, duration_us}` | a batch reaches the store |
| `[:pixelex, :ingest, :drop]` | `%{count}`, `%{reason}` | the buffer shed load |
| `[:pixelex, :pipeline, :drop]` | `%{count}`, `%{reason, site_id}` | an event was refused |

Watch the drops. Silent loss is the danger, not loss.

## Not written yet

A Flutter/mobile SDK — the HTTP ingest endpoint accepts events from anything in
the meantime. Rollup tables (raw events answer everything inside the retention
window today). ClickHouse and DuckDB store adapters, which the `Pixelex.Store`
behaviour has room for.

## Licence

Apache-2.0.
