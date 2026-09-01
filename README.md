# pixelex

Cookieless, multi-tenant, first-party analytics for Phoenix. Web visitors,
product events and ad-platform attribution over **one event log**, in your own
Postgres.

> **Status: 0.1.0-dev.** The engine and capture surfaces work and are tested.
> The query layer, dashboard, ad-platform destinations and JS tracker are not
> written yet — see [Roadmap](#roadmap).

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
Nothing on Hex does ad-platform Conversions API dispatch at all.

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

```elixir
def deps do
  [
    {:pixelex, "~> 0.1"},

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

## Telemetry

| event | measurements | when |
|---|---|---|
| `[:pixelex, :ingest, :push]` | `%{count}` | an event is queued |
| `[:pixelex, :ingest, :flush]` | `%{count, bytes, written, duration_us}` | a batch reaches the store |
| `[:pixelex, :ingest, :drop]` | `%{count}`, `%{reason}` | the buffer shed load |
| `[:pixelex, :pipeline, :drop]` | `%{count}`, `%{reason, site_id}` | an event was refused |

Watch the drops. Silent loss is the danger, not loss.

## Roadmap

- [x] Event schema, ingest buffer, Postgres + ETS stores, partitions, retention
- [x] Cookieless identity, salt rotation, sessions, midnight handover
- [x] Auto-attribution: click ids, UTM, referrer classification, first/last touch
- [x] Consent gate, `Sec-GPC`, bot filtering, rate limiting
- [x] `Plug`, `Plug.Ingest`, `Plug.Session`, LiveView `on_mount`
- [ ] Ad-platform destinations (Meta CAPI, TikTok, Snap, GA4, and others)
- [ ] Query layer: traffic, funnels, retention, cohorts
- [ ] LiveView dashboard
- [ ] JS tracker, Igniter installer, Flutter SDK
- [ ] Release: ExDoc, CI, hex.publish

## Licence

Apache-2.0.
