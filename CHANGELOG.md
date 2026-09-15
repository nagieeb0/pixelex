# Changelog

## 0.4.1 — 2026-09-15

- Optional enrichment dependencies now compile without warnings when a host
  deliberately omits them. No behaviour or migration change.

## 0.4.0 — 2026-09-15

The browser tracker can now explain what a visitor could do, what they did and
how far they got, without turning page copy or form values into analytics data.

### Added
- Automatic discovery of visible links, buttons, submit controls,
  `role="button"` elements and `summary` controls, including LiveView DOM
  updates through `MutationObserver`.
- `px.inventory`, `px.click` and richer `px.engagement` events. Library-owned
  browser events form a closed built-in allowlist; arbitrary `px.*` names remain
  rejected.
- Semantic action inference for booking, WhatsApp, phone, submit, expand,
  navigation and generic interactions.
- Optional `data-track-action`, `data-track-label`, `data-track-section` and
  `data-pixelex-ignore` controls, plus script-level
  `data-interactions="false"`.
- `Pixelex.Query.Interactions` and dashboard panels for page inventory,
  interactions, scroll depth, active time and the latest event timeline.

### Changed
- Pixel and site settings save after a short debounce. Pasting a recognised
  platform snippet saves the detected fields immediately; secret fields still
  remain write-only and a blank secret keeps the stored value.

### Privacy
- Automatic interaction capture never reads element text, `innerText`,
  `textContent` or form values. A business label is collected only when the
  host intentionally sets `data-track-label`.
- No migration.

## 0.3.0 — 2026-09-02

Two conversion-delivery faults, and a pixel id that is finally worth something
on its own.

### Fixed
- **Every conversion arrived with an empty `user_data`.** `from_args/1` ran the
  match keys through the *credential* allowlist, so `email`, `phone`, `ip`,
  `user_agent` and every click id were dropped between the enqueue and the
  platform client. Both delivery paths went through it. Meta rejects that
  payload outright; the rest accept it and match nobody. There is now a
  `@user_data_keys` allowlist covering every key the seven clients read, and a
  round-trip test asserting Meta receives them.
- **`custom_data` is no longer filtered.** Meta, TikTok, Snapchat and Pinterest
  forward the whole map, so a host's own properties were being collapsed. It is
  passed through untouched; every named read in the clients already accepted
  string keys.
- **Oban was never detected.** `oban?/0` used `Process.whereis(Oban)`, but Oban
  registers its supervisor through `Oban.Registry`, so the check was `nil` on a
  healthy Oban: every conversion took the unsupervised `Task` branch with no
  retry, and every host that had installed Oban was told to install Oban. Add
  `config :pixelex, oban_name: MyApp.Oban` for a custom instance name.

### Added
- `Pixelex.Pixels` — renders the tenant's browser pixel from the ids they
  already saved. `<Pixelex.Pixels.tags site_id={@site_id} consent={@consent} />`
  in the root layout, and a pasted pixel id starts firing with no deploy. Meta,
  TikTok, Snapchat, GA4, Reddit, Pinterest and LinkedIn. Ids are validated
  against `[A-Za-z0-9._-]{1,64}` before they reach a `<script>`; consent is
  honoured; `nonce` is supported for CSP.
- The settings card has three states rather than two: **not set up**,
  **browser pixel active** (an id, no token — what a Shopify-style platform
  gives a merchant, and what pixelex used to give nothing for), and
  **browser + server, deduped**.
- `tag_id` on Pinterest and `partner_id` on LinkedIn, both optional and used
  only by the browser pixel. Pinterest's server API authenticates with an ad
  account id and its tag loads with a different number entirely.

### Notes
- No migration.
- 324 → 356 tests.

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
