# Changelog

## 0.2.0 — 2026-09-02

Ad-platform credentials stop being a deploy.

### Added
- `Pixelex.Dashboard.Settings` and `pixelex_settings/2` — a screen where a
  tenant pastes the snippet their ad platform gave them, presses **Test**, and
  sees a live `page_view` accepted or rejected by the platform's own API. Secrets
  are written and never rendered back; *Disconnect* removes one.
- `Pixelex.Destinations.Detect` — pulls the id out of a Meta, GA4, TikTok,
  Snapchat, Reddit, LinkedIn or Pinterest snippet, in the paste box or in any
  individual field. Declines to guess at anything without a distinguishing
  shape rather than filing a token under the wrong platform.
- `c:Pixelex.Destination.fields/0`, implemented by all seven built-ins. A
  custom destination that implements it gets a settings card for free.
- `Pixelex.Secrets` — opt-in AES-256-GCM at rest under
  `config :pixelex, secret_key:`. Turning it on is not a migration: plaintext
  keeps reading and becomes ciphertext on the next save. A credential that
  cannot be decrypted reads as `nil`, so the platform behaves as unconfigured
  instead of authenticating with ciphertext.
- `Pixelex.Destinations.put_credentials/3`, `delete_credentials/2`, `test/2`,
  `fields/1`, `configurable/0`, `module/1`.
- `Pixelex.Sites.update/2` — partial update, leaving untouched columns alone.

### Changed
- `Pixelex.Destinations.credentials/1` decrypts secret fields on the way out.
- The dashboard stylesheet is shared with the settings screen; still no
  Tailwind, no chart library, no CDN.

### Notes
- No migration. `pixelex_sites.destinations` already held this.
- 265 → 323 tests.

## 0.1.0 — 2026-09-02

First release.

### Capture
- `Pixelex.Plug` — server-side page views, no JavaScript
- `Pixelex.LiveView` — an `on_mount` hook covering initial, `live_patch` and
  `live_navigate`, with reconnect and duplicate-render handling
- `Pixelex.Plug.Ingest` — `POST /px/e`, `GET /px.gif`, `GET /px/pixelex.js`
- `Pixelex.Plug.Session` — carries the referrer and country into the socket
- A 1,458-byte (gzipped) browser tracker

### Identity
- Cookieless visitor hashing, HMAC-SHA256 under a daily-rotating salt
- Scheduler-free rotation, keyed on the UTC date
- The midnight session handover, via the previous day's salt
- Sessions in ETS, 30-minute inactivity, page-view deduplication

### Attribution
- 26 paid click-id parameters across 15 networks
- Referrer classification and user-agent parsing via `ref_inspector` /
  `ua_inspector`, both optional with graceful degradation
- First and last touch, session-scoped

### Consent
- Geo-scoped gate for the EEA, UK and Switzerland; ships off
- `Sec-GPC` honoured server-side; `DNT` available as a courtesy
- Ad-platform forwarding gated separately and more tightly

### Storage
- Partitioned Postgres, no extensions required
- ETS adapter for tests and dev
- `DROP PARTITION` retention

### Queries
- Traffic, timeseries, pages, sources, mediums, campaigns, geography, devices
- Ordered multi-step funnels with an optional conversion window
- Retention cohorts, on identified users

### Ad platforms
- Meta, TikTok, Snapchat, GA4, Pinterest, Reddit, LinkedIn
- Durable delivery through Oban with `event_id` deduplication

### Dashboard
- One LiveView, no Tailwind, no chart library, no CDN
