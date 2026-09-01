defmodule Pixelex do
  @moduledoc """
  Cookieless, multi-tenant, first-party analytics for Phoenix.

  Web visitors, product events and ad-platform attribution over **one event
  log**, stored in the host application's own Postgres.

  ## Three surfaces, one call

      # a page view, from a Plug or a LiveView hook
      Pixelex.page(context)

      # a product event
      Pixelex.track(context, "booking_completed", %{value: 1499.0, currency: "EGP"})

      # tie the anonymous visitor to a signed-in user
      Pixelex.identify(context, user.id)

  `context` is a map the capture layer builds; see `Pixelex.Pipeline`. Every one
  of these returns `:ok` or `{:dropped, reason}` and **never raises**, because
  the call sites are page loads, bookings and payments.

  ## Where the visitor came from, with nothing to configure

  No UTM tags are required. Ad platforms already stamp a click id on every
  click they sell — `fbclid`, `gclid`, `ttclid`, twenty-odd others — and
  browsers already send a referrer. `Pixelex.Attribution` reads both.

  ## Who the visitor is, with nothing stored on their device

  A keyed hash of user agent, IP and site, under a salt that rotates every UTC
  day and is deleted after two. Nothing is written to or read from the device,
  so the ePrivacy cookie rule is not engaged and no banner is required for
  first-party analytics. Ad-platform forwarding is a separate, narrower gate —
  see `Pixelex.Consent`.

  ## Setup

      # mix.exs
      {:pixelex, "~> 0.1"},
      {:ref_inspector, "~> 2.0"},   # optional, strongly recommended
      {:ua_inspector, "~> 3.0"}     # optional, strongly recommended

      # config
      config :pixelex, repo: MyApp.Repo

      # a migration
      defmodule MyApp.Repo.Migrations.AddPixelex do
        use Ecto.Migration
        def up, do: Pixelex.Migration.up()
        def down, do: Pixelex.Migration.down()
      end

  Then `mix ref_inspector.download` and `mix ua_inspector.download`, including
  in the release build — those databases are fetched, not bundled.

  Keep `Pixelex.Partitions.ensure/1` on a daily schedule. A range-partitioned
  table with no partition covering today rejects every insert, and nothing
  degrades gracefully: ingestion simply stops at midnight on the first of the
  month.
  """

  alias Pixelex.Pipeline

  @doc """
  Record a page view.

  Uses the reserved name `px.pageview`.
  """
  @spec page(Pipeline.context(), map()) :: Pipeline.result()
  def page(context, props \\ %{}), do: Pipeline.run(context, Pipeline.pageview_name(), props)

  @doc """
  Record a named event.

      Pixelex.track(context, "booking_completed", %{value: 1499.0, currency: "EGP"})

  Names are capped at 120 characters and `props` at 50 keys; both are written
  from an unauthenticated endpoint in the browser case, and a field with no
  ceiling is a disk-filling primitive.
  """
  @spec track(Pipeline.context(), String.t() | atom(), map()) :: Pipeline.result()
  def track(context, name, props \\ %{}), do: Pipeline.run(context, name, props)

  @doc """
  Attach a user id to the current visitor and session.

  Emits `px.identify`, so the join from anonymous history to a known user is a
  row in the log rather than a mutation of past rows — the events before the
  signup keep saying what they said at the time, and the funnel can still be
  rebuilt from either end.
  """
  @spec identify(Pipeline.context(), String.t(), map()) :: Pipeline.result()
  def identify(context, user_id, traits \\ %{}) when is_binary(user_id) do
    context
    |> Map.put(:user_id, user_id)
    |> Pipeline.run("px.identify", traits)
  end

  @doc "Flush buffered events to the store now. Shutdown hooks and tests."
  @spec flush(timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate flush(timeout \\ 15_000), to: Pixelex.Ingest
end
