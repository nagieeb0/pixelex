defmodule Pixelex.PipelineTest do
  use ExUnit.Case, async: false

  alias Pixelex.{Ingest, Sessions, Store}

  @chrome "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"
  @ip "197.55.10.3"

  setup do
    Application.put_env(:pixelex, :store, Store.ETS)
    Application.put_env(:pixelex, :salt_persistence, :memory)
    Ingest.flush()
    Store.ETS.reset()
    Sessions.reset()

    on_exit(fn ->
      Application.delete_env(:pixelex, :consent_gate)
      Sessions.reset()
    end)

    :ok
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        site_id: "shop",
        ip: @ip,
        user_agent: @chrome,
        url: "https://shop.test/pricing",
        referrer: nil,
        hostname: "shop.test",
        country: "EG",
        render: :connected,
        consent: %{}
      },
      overrides
    )
  end

  defp stored do
    Ingest.flush()
    Store.ETS.all()
  end

  describe "a visit arriving from a paid ad" do
    test "is attributed, sessionised and enriched without any configuration" do
      assert :ok =
               Pixelex.page(
                 context(%{url: "https://shop.test/pricing?gclid=Cj0KCQ&utm_campaign=ramadan"})
               )

      assert [event] = stored()

      # attribution — no UTM source was set anywhere
      assert event.attribution["last"]["network"] == "google"
      assert event.attribution["last"]["medium"] == "paid_search"
      assert event.attribution["last"]["click_id"] == "Cj0KCQ"
      assert event.attribution["last"]["campaign"] == "ramadan"

      # identity — cookieless, and present
      assert is_binary(event.visitor_id)
      assert is_binary(event.session_id)

      # enrichment — from the request alone
      assert event.browser == "Chrome Mobile"
      assert event.os == "Android"
      assert event.device_type == "smartphone"

      # shape
      assert event.name == "px.pageview"
      assert event.pathname == "/pricing"
      assert event.hostname == "shop.test"
      assert event.render == :connected
      assert event.country == "EG"
    end

    test "organic search is classified and the search term recovered" do
      assert :ok =
               Pixelex.page(
                 context(%{referrer: "https://www.google.com/search?q=teeth+whitening+cairo"})
               )

      assert [event] = stored()
      assert event.attribution["last"]["source"] == "Google"
      assert event.attribution["last"]["medium"] == "organic_search"
      assert event.attribution["last"]["term"] == "teeth whitening cairo"
    end
  end

  describe "a session across several events" do
    test "keeps one session id and one first touch" do
      Pixelex.page(context(%{url: "https://shop.test/?fbclid=IwAR9"}))
      Pixelex.page(context(%{url: "https://shop.test/pricing", referrer: "https://shop.test/"}))
      Pixelex.track(context(), "booking_completed", %{"value" => 1499.0, "currency" => "EGP"})

      events = stored()
      assert length(events) == 3

      assert [session] = events |> Enum.map(& &1.session_id) |> Enum.uniq()
      assert is_binary(session)

      assert [visitor] = events |> Enum.map(& &1.visitor_id) |> Enum.uniq()
      assert is_binary(visitor)

      # Every event in the session carries the ad that started it, including the
      # conversion — which is the entire point of storing first touch.
      for event <- events do
        assert event.attribution["first"]["network"] == "facebook"
      end

      conversion = Enum.find(events, &(&1.name == "booking_completed"))
      assert conversion.props == %{"value" => 1499.0, "currency" => "EGP"}
    end

    test "an internal click does not overwrite the ad as last touch" do
      Pixelex.page(context(%{url: "https://shop.test/?ttclid=T1"}))
      Pixelex.page(context(%{url: "https://shop.test/pricing", referrer: "https://shop.test/"}))

      last = stored() |> List.last()
      assert last.attribution["last"]["network"] == "tiktok"
    end

    test "identify/3 attaches a user without rewriting earlier events" do
      Pixelex.page(context())
      assert :ok = Pixelex.identify(context(), "user-123")

      [pageview, identify] = stored()

      assert pageview.user_id == nil, "history keeps saying what it said at the time"
      assert identify.user_id == "user-123"
      assert identify.name == "px.identify"
      assert identify.session_id == pageview.session_id
    end
  end

  describe "what gets dropped" do
    test "crawlers" do
      assert {:dropped, :bot} =
               Pixelex.page(
                 context(%{
                   user_agent:
                     "Mozilla/5.0 (compatible; Googlebot/2.1; +http://google.com/bot.html)"
                 })
               )

      assert stored() == []
    end

    test "HTTP libraries pretending to be traffic" do
      assert {:dropped, :bot} = Pixelex.page(context(%{user_agent: "python-requests/2.31.0"}))
    end

    test "a visitor sending Sec-GPC" do
      assert {:dropped, :gpc} = Pixelex.page(context(%{consent: %{gpc: "1"}}))
      assert stored() == []
    end

    test "an unanswered banner in a gated country" do
      Application.put_env(:pixelex, :consent_gate, enabled: true)

      assert {:dropped, :no_consent} =
               Pixelex.page(context(%{country: "DE", consent: %{country: "DE", decision: nil}}))

      assert :ok =
               Pixelex.page(
                 context(%{country: "DE", consent: %{country: "DE", decision: "granted"}})
               )
    end

    test "an event with no site" do
      assert {:dropped, :invalid_site_id} = Pixelex.track(context(%{site_id: nil}), "x")
    end

    test "an event with an unusable name" do
      assert {:dropped, :invalid_name} = Pixelex.track(context(), "   ")
      assert {:dropped, :name_too_long} = Pixelex.track(context(), String.duplicate("x", 121))
    end

    test "every drop is counted, with its reason" do
      :telemetry.attach(
        "pipeline-drop",
        [:pixelex, :pipeline, :drop],
        fn _e, m, meta, pid -> send(pid, {:drop, m.count, meta.reason}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("pipeline-drop") end)

      Pixelex.page(context(%{consent: %{gpc: "1"}}))
      assert_receive {:drop, 1, :gpc}
    end
  end

  describe "server-side calls" do
    test "are not bot-filtered, because the host made them deliberately" do
      # A Flutter SDK sends an HTTP-library agent. Rejecting it would drop real
      # events to catch traffic that never arrives this way.
      assert :ok =
               Pixelex.track(
                 context(%{user_agent: "Dart/3.5 (dart:io)", render: :server}),
                 "appointment_booked"
               )

      assert [event] = stored()
      assert event.render == :server
    end

    test "work with almost nothing in the context" do
      assert :ok = Pixelex.track(%{site_id: "shop"}, "cron_ran")
      assert [event] = stored()
      assert event.name == "cron_ran"
      assert event.render == :server
    end
  end

  describe "resilience" do
    test "a malformed URL does not stop the event being recorded" do
      assert :ok = Pixelex.page(context(%{url: "://nonsense", referrer: "%%%"}))
      assert [_event] = stored()
    end

    test "two different visitors are two different sessions" do
      Pixelex.page(context())
      Pixelex.page(context(%{ip: "41.33.1.9"}))

      assert stored() |> Enum.map(& &1.session_id) |> Enum.uniq() |> length() == 2
    end
  end
end
