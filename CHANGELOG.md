# Changelog

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
