defmodule Pixelex.DestinationsTest do
  use ExUnit.Case, async: false

  alias Pixelex.Destinations
  alias Pixelex.Destinations.{GA4, Hash, Meta, Snapchat, TikTok}

  # The exact payload is the part that fails silently: a wrong field name gets a
  # 200 and matches nobody. So these assert on the bytes, against a stub.
  setup do
    Application.put_env(:pixelex, :req_options, plug: {Req.Test, PixelexStub})

    on_exit(fn ->
      Application.delete_env(:pixelex, :req_options)
      Application.delete_env(:pixelex, :sites)
    end)

    :ok
  end

  defp capture(status \\ 200, body \\ %{}) do
    parent = self()

    Req.Test.stub(PixelexStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:request, %{url: request_url(conn), headers: conn.req_headers, body: decode(raw)}}
      )

      Req.Test.json(%{conn | status: status}, body)
    end)
  end

  defp request_url(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "#{conn.scheme}://#{conn.host}#{conn.request_path}#{query}"
  end

  defp decode(""), do: %{}
  defp decode(raw), do: Jason.decode!(raw)

  defp conversion(overrides \\ %{}) do
    Map.merge(
      %{
        event_id: "order:42",
        event_time: 1_756_000_000,
        event_source_url: "https://shop.test/checkout",
        user_data: %{},
        custom_data: %{}
      },
      overrides
    )
  end

  # The email SHA-256 every platform must agree on.
  @email "  Ali@Example.COM "
  @email_hash Base.encode16(:crypto.hash(:sha256, "ali@example.com"), case: :lower)
  @phone "+20 (100) 123-4567"
  @phone_digits Base.encode16(:crypto.hash(:sha256, "201001234567"), case: :lower)
  @phone_e164 Base.encode16(:crypto.hash(:sha256, "+201001234567"), case: :lower)

  describe "Hash — the normalisation each platform demands" do
    test "email is trimmed and lower-cased before hashing" do
      assert Hash.email(@email) == @email_hash
      assert Hash.email("ali@example.com") == @email_hash
      assert Hash.email(nil) == nil
      assert Hash.email("  ") == nil
    end

    test "Meta, Snapchat and Pinterest want digits; TikTok keeps the plus" do
      assert Hash.phone_digits(@phone) == @phone_digits
      assert Hash.phone_e164(@phone) == @phone_e164

      refute Hash.phone_digits(@phone) == Hash.phone_e164(@phone),
             "if these ever match, one platform's matching has silently broken"
    end

    test "an already-hashed value is not hashed a second time" do
      # Double-hashing produces a digest that matches nothing, and nothing
      # anywhere reports an error — the conversions just stop attributing.
      assert Hash.email(@email_hash) == @email_hash
      assert Hash.phone_digits(@phone_digits) == @phone_digits
      assert Hash.text(String.upcase(@email_hash)) == @email_hash
    end

    test "hashed?/1 recognises a digest and nothing else" do
      assert Hash.hashed?(@email_hash)
      refute Hash.hashed?("ali@example.com")
      refute Hash.hashed?(String.slice(@email_hash, 0, 63))
      refute Hash.hashed?(nil)
    end

    test "compact/1 drops what platforms reject" do
      assert Hash.compact(%{a: 1, b: nil, c: "", d: [], e: %{}}) == %{a: 1}
    end
  end

  describe "Meta" do
    test "no-ops without both a pixel and a token" do
      refute Meta.configured?(%{pixel_id: "1", access_token: ""})
      refute Meta.configured?(%{pixel_id: nil, access_token: "t"})
      refute Meta.configured?(%{})
      assert Meta.configured?(%{pixel_id: "1", access_token: "t"})
    end

    test "sends hashed match keys as arrays, raw ones as strings" do
      capture()

      Meta.deliver(
        %{pixel_id: "PIX", access_token: "TOK"},
        "Purchase",
        conversion(%{
          user_data: %{email: @email, phone: @phone, ip: "197.55.10.3", user_agent: "UA"},
          custom_data: %{currency: "EGP", value: 1499.0}
        })
      )

      assert_receive {:request, req}
      assert req.url =~ "/PIX/events"
      assert req.body["access_token"] == "TOK"

      [event] = req.body["data"]
      assert event["event_name"] == "Purchase"
      assert event["event_id"] == "order:42"
      assert event["event_time"] == 1_756_000_000
      assert event["action_source"] == "website"

      ud = event["user_data"]

      # Arrays, not strings. Meta accepts a bare string with a 200 and then
      # matches nothing.
      assert ud["em"] == [@email_hash]
      assert ud["ph"] == [@phone_digits]
      assert ud["client_ip_address"] == "197.55.10.3"
      assert ud["client_user_agent"] == "UA"

      assert event["custom_data"] == %{"currency" => "EGP", "value" => 1499.0}
    end

    test "builds fbc from a captured fbclid" do
      capture()

      Meta.deliver(
        %{pixel_id: "PIX", access_token: "TOK"},
        "Lead",
        conversion(%{user_data: %{fbclid: "IwAR9x", clicked_at_ms: 1_756_000_000_000}})
      )

      assert_receive {:request, req}
      [event] = req.body["data"]
      assert event["user_data"]["fbc"] == "fb.1.1756000000000.IwAR9x"
    end

    test "an explicit fbc wins over a reconstructed one" do
      capture()

      Meta.deliver(
        %{pixel_id: "P", access_token: "T"},
        "Lead",
        conversion(%{user_data: %{fbc: "fb.1.111.given", fbclid: "other"}})
      )

      assert_receive {:request, req}
      assert hd(req.body["data"])["user_data"]["fbc"] == "fb.1.111.given"
    end

    test "fbc/2 refuses to invent a click id" do
      assert Meta.fbc(nil) == nil
      assert Meta.fbc("") == nil
      assert Meta.fbc("abc", 1000) == "fb.1.1000.abc"
    end

    test "passes the test event code through so a payload can be verified" do
      capture()

      Meta.deliver(
        %{pixel_id: "P", access_token: "T", test_event_code: "TEST123"},
        "Purchase",
        conversion()
      )

      assert_receive {:request, req}
      assert req.body["test_event_code"] == "TEST123"
    end

    test "reports a rejection rather than swallowing it" do
      capture(400, %{"error" => %{"message" => "Invalid parameter"}})

      assert {:error, {:meta, 400, _}} =
               Meta.deliver(%{pixel_id: "P", access_token: "T"}, "Purchase", conversion())
    end
  end

  describe "TikTok" do
    test "hashes the phone in E.164 and sends match keys as plain strings" do
      capture(200, %{"code" => 0})

      TikTok.deliver(
        %{pixel_code: "C8", access_token: "TOK"},
        "CompletePayment",
        conversion(%{user_data: %{email: @email, phone: @phone, ttclid: "T1"}})
      )

      assert_receive {:request, req}
      assert req.body["event_source_id"] == "C8"
      assert req.body["event_source"] == "web"

      [event] = req.body["data"]
      assert event["event"] == "CompletePayment"

      # Strings, not arrays — the opposite of Meta.
      assert event["user"]["email"] == @email_hash
      assert event["user"]["phone"] == @phone_e164
      assert event["user"]["ttclid"] == "T1"
      assert event["page"] == %{"url" => "https://shop.test/checkout"}
    end

    test "sends the token as a header, not in the body" do
      capture(200, %{"code" => 0})
      TikTok.deliver(%{pixel_code: "C8", access_token: "SECRET"}, "Search", conversion())

      assert_receive {:request, req}
      assert {"access-token", "SECRET"} in req.headers
      refute req.body["access_token"]
    end

    test "a 200 carrying an error code is a failure, not a success" do
      # The trap this whole :success predicate exists for.
      capture(200, %{"code" => 40_001, "message" => "Invalid pixel code"})

      assert {:error, {:tiktok, 200, _}} =
               TikTok.deliver(%{pixel_code: "C8", access_token: "T"}, "Search", conversion())
    end

    test "a 200 with code 0 is success" do
      capture(200, %{"code" => 0})
      assert :ok = TikTok.deliver(%{pixel_code: "C8", access_token: "T"}, "Search", conversion())
    end
  end

  describe "Snapchat" do
    test "puts the token in the query string and hashes the phone as digits" do
      capture()

      Snapchat.deliver(
        %{pixel_id: "SNAP", access_token: "tok en"},
        "PURCHASE",
        conversion(%{user_data: %{email: @email, phone: @phone, sc_click_id: "S1"}})
      )

      assert_receive {:request, req}
      assert req.url =~ "/v3/SNAP/events"
      assert req.url =~ "access_token=tok+en", "the token must be form-encoded"

      [event] = req.body["data"]
      assert event["action_source"] == "WEB"
      assert event["user_data"]["em"] == [@email_hash]
      assert event["user_data"]["ph"] == [@phone_digits]
      assert event["user_data"]["sc_click_id"] == "S1"
    end

    test "accepts the raw sccid parameter name too" do
      capture()

      Snapchat.deliver(
        %{pixel_id: "S", access_token: "T"},
        "PURCHASE",
        conversion(%{user_data: %{sccid: "from-url"}})
      )

      assert_receive {:request, req}
      assert hd(req.body["data"])["user_data"]["sc_click_id"] == "from-url"
    end
  end

  describe "GA4" do
    test "sends no personal data, because there is no API for it" do
      capture(204)

      GA4.deliver(
        %{measurement_id: "G-ABC", api_secret: "SEC"},
        "purchase",
        conversion(%{
          user_data: %{email: @email, phone: @phone},
          custom_data: %{currency: "EGP", value: 1499.0}
        })
      )

      assert_receive {:request, req}
      encoded = Jason.encode!(req.body)

      refute encoded =~ "ali@example.com"
      refute encoded =~ @email_hash
      refute encoded =~ "201001234567"
    end

    test "keys the event to a client id and carries the measurement credentials in the query" do
      capture(204)
      GA4.deliver(%{measurement_id: "G-ABC", api_secret: "SEC"}, "purchase", conversion())

      assert_receive {:request, req}
      assert req.url =~ "measurement_id=G-ABC"
      assert req.url =~ "api_secret=SEC"

      assert is_binary(req.body["client_id"])
      [event] = req.body["events"]
      assert event["name"] == "purchase"
      assert event["params"]["transaction_id"] == "order:42"
      # Without this GA4 detaches the event from the session in every report.
      assert event["params"]["engagement_time_msec"] == 1
    end

    test "a forwarded browser client id is preferred over the synthetic one" do
      capture(204)

      GA4.deliver(
        %{measurement_id: "G", api_secret: "S"},
        "purchase",
        conversion(%{user_data: %{client_id: "GA1.1.123.456"}})
      )

      assert_receive {:request, req}
      assert req.body["client_id"] == "GA1.1.123.456"
    end

    test "the synthetic client id is stable across retries of the same event" do
      capture(204)
      GA4.deliver(%{measurement_id: "G", api_secret: "S"}, "purchase", conversion())
      assert_receive {:request, first}

      capture(204)
      GA4.deliver(%{measurement_id: "G", api_secret: "S"}, "purchase", conversion())
      assert_receive {:request, second}

      assert first.body["client_id"] == second.body["client_id"]
    end
  end

  describe "Pinterest" do
    alias Pixelex.Destinations.Pinterest

    test "scopes by ad account, sends hashed keys as arrays and value as a string" do
      capture(200, %{"num_events_received" => 1, "num_events_processed" => 1})

      Pinterest.deliver(
        %{ad_account_id: "ACC1", access_token: "pina_tok"},
        "checkout",
        conversion(%{
          user_data: %{email: @email, phone: @phone, epik: "EPIK1", ip: "1.2.3.4"},
          custom_data: %{currency: "USD", value: 66.95}
        })
      )

      assert_receive {:request, req}
      assert req.url =~ "/v5/ad_accounts/ACC1/events"
      assert {"authorization", "Bearer pina_tok"} in req.headers

      [event] = req.body["data"]
      assert event["event_name"] == "checkout"
      assert event["action_source"] == "web"
      assert event["user_data"]["em"] == [@email_hash]
      assert event["user_data"]["ph"] == [@phone_digits], "Pinterest wants digits, no plus"
      assert event["user_data"]["click_id"] == "EPIK1"

      # A string Pinterest parses to a double, unlike every other platform here.
      assert event["custom_data"]["value"] == "66.95"
    end

    test "a 200 carrying a failed event is a failure" do
      # The trap: Pinterest reports rejections inside a 200 body, in a
      # per-event array nobody looks at.
      capture(200, %{
        "num_events_received" => 1,
        "num_events_processed" => 0,
        "events" => [%{"status" => "failed", "error_message" => "Invalid event_name"}]
      })

      assert {:error, {:pinterest, 200, _}} =
               Pinterest.deliver(
                 %{ad_account_id: "A", access_token: "T"},
                 "purchase",
                 conversion()
               )
    end

    test "a partially processed batch is a failure too" do
      capture(200, %{"num_events_received" => 2, "num_events_processed" => 1})

      assert {:error, _} =
               Pinterest.deliver(
                 %{ad_account_id: "A", access_token: "T"},
                 "checkout",
                 conversion()
               )
    end
  end

  describe "Reddit" do
    alias Pixelex.Destinations.Reddit

    test "wraps events in data, uses milliseconds, and names the type in v3 casing" do
      capture(200, %{"data" => %{"message" => "ok"}})

      Reddit.deliver(
        %{pixel_id: "a2_1", access_token: "tok"},
        "PURCHASE",
        conversion(%{
          user_data: %{email: "Al.ice+Apple@Example.Com", phone: @phone, rdt_cid: "RC1"},
          custom_data: %{currency: "USD", value: 66.95}
        })
      )

      assert_receive {:request, req}
      assert req.url =~ "/api/v3/pixels/a2_1/conversion_events"

      [event] = req.body["data"]["events"]
      assert event["event_at"] == 1_756_000_000_000, "milliseconds, not seconds"
      assert event["action_source"] == "WEBSITE"
      assert event["type"] == %{"tracking_type" => "PURCHASE"}
      assert event["click_id"] == "RC1"

      # Reddit's own published vector for both spellings of this address.
      assert event["user"]["email"] ==
               "ff8d9819fc0e12bf0d24892e45987e249a28dce836a85cad60e28eaaa8c6d976"

      assert event["user"]["phone_number"] == @phone_e164, "E.164 with the plus kept"

      # The dedup key is metadata.conversion_id here, not event_id.
      assert event["metadata"]["conversion_id"] == "order:42"
      assert event["metadata"]["value"] == 66.95
    end

    test "an event with no standard type travels as CUSTOM with a name" do
      capture(200, %{})
      Reddit.deliver(%{pixel_id: "p", access_token: "t"}, "InitiateCheckout", conversion())

      assert_receive {:request, req}
      [event] = req.body["data"]["events"]

      assert event["type"] == %{
               "tracking_type" => "CUSTOM",
               "custom_event_name" => "InitiateCheckout"
             }
    end

    test "identifies itself, because Reddit rate-limits generic agents by name" do
      capture(200, %{})
      Reddit.deliver(%{pixel_id: "p", access_token: "t"}, "LEAD", conversion())

      assert_receive {:request, req}
      {_name, ua} = List.keyfind(req.headers, "user-agent", 0)
      assert ua =~ "pixelex"
    end
  end

  describe "LinkedIn" do
    alias Pixelex.Destinations.LinkedIn

    @credentials %{
      access_token: "tok",
      conversions: %{"PURCHASE" => "urn:lla:llaPartnerConversion:123"}
    }

    test "needs a conversion rule before it is configured at all" do
      refute LinkedIn.configured?(%{access_token: "t", conversions: %{}})
      refute LinkedIn.configured?(%{access_token: "t"})
      assert LinkedIn.configured?(@credentials)
    end

    test "references the rule URN and sends the required version headers" do
      capture(201, %{})

      LinkedIn.deliver(
        @credentials,
        "PURCHASE",
        conversion(%{
          user_data: %{email: @email, ip: "1.2.3.4", li_fat_id: "LI1"},
          custom_data: %{currency: "USD", value: 66.95}
        })
      )

      assert_receive {:request, req}
      assert req.url =~ "/rest/conversionEvents"
      assert {"x-restli-protocol-version", "2.0.0"} in req.headers
      assert {"linkedin-version", "202608"} in req.headers

      assert req.body["conversion"] == "urn:lla:llaPartnerConversion:123"
      assert req.body["conversionHappenedAt"] == 1_756_000_000_000
      assert req.body["conversionValue"] == %{"currencyCode" => "USD", "amount" => "66.95"}

      ids = req.body["user"]["userIds"]
      assert %{"idType" => "SHA256_EMAIL", "idValue" => @email_hash} in ids
      assert %{"idType" => "PLAINTEXT_IP_ADDRESS", "idValue" => "1.2.3.4"} in ids
      assert %{"idType" => "LINKEDIN_FIRST_PARTY_ADS_TRACKING_UUID", "idValue" => "LI1"} in ids
    end

    test "always sends userIds, even empty" do
      # Omitting it is a 422: "field is required but not found and has no
      # default value" — even when the user is identified another way.
      capture(201, %{})
      LinkedIn.deliver(@credentials, "PURCHASE", conversion())

      assert_receive {:request, req}
      assert req.body["user"]["userIds"] == []
    end

    test "refuses an IPv6 address rather than having it rejected" do
      capture(201, %{})
      LinkedIn.deliver(@credentials, "PURCHASE", conversion(%{user_data: %{ip: "2001:db8::1"}}))

      assert_receive {:request, req}
      assert req.body["user"]["userIds"] == []
    end

    test "skips an event type with no rule instead of guessing one" do
      # Attributing a purchase to whichever rule happened to be first would put
      # revenue in the leads report.
      capture(201, %{})
      assert :ok = LinkedIn.deliver(@credentials, "LEAD", conversion())
      refute_receive {:request, _}, 100
    end

    test "sends no phone number, because LinkedIn has no field for one" do
      capture(201, %{})
      LinkedIn.deliver(@credentials, "PURCHASE", conversion(%{user_data: %{phone: @phone}}))

      assert_receive {:request, req}
      refute Jason.encode!(req.body) =~ @phone_digits
    end
  end

  describe "the canonical event table" do
    test "every platform maps every canonical event, or says it cannot" do
      for {event, mapping} <- Destinations.dialects() do
        assert event in Destinations.canonical_events()

        for {platform, name} <- mapping do
          assert is_nil(name) or (is_binary(name) and name != ""),
                 "#{platform} gave #{inspect(name)} for #{event}"
        end
      end
    end

    test "the money event exists on every platform" do
      purchase = Destinations.dialects()[:purchase]

      assert Enum.all?(purchase, fn {_platform, name} -> is_binary(name) end),
             "purchase must reach everywhere: #{inspect(purchase)}"
    end

    test "Pinterest calls a purchase `checkout`, because it has no `purchase`" do
      # Sending "purchase" is an explicit rejection from Pinterest, delivered
      # inside a 200 response body where nobody looks.
      assert Destinations.dialects()[:purchase][:pinterest] == "checkout"
    end

    test "Reddit v3 event names are UPPER_SNAKE_CASE, not the v2 CamelCase" do
      # v2 used PageVisit/AddToCart/SignUp. Copying a pre-October-2025 example
      # silently creates custom events named after standard ones.
      dialects = Destinations.dialects()

      assert dialects[:page_view][:reddit] == "PAGE_VISIT"
      assert dialects[:add_to_cart][:reddit] == "ADD_TO_CART"
      assert dialects[:complete_registration][:reddit] == "SIGN_UP"
    end

    test "LinkedIn returns a rule type, not a wire event name" do
      # LinkedIn has no event name on the wire at all; the type selects which
      # pre-created conversion rule URN to reference.
      assert Destinations.dialects()[:page_view][:linkedin] == "KEY_PAGE_VIEW"
    end

    test "a platform with no equivalent says nil rather than inventing one" do
      assert Destinations.dialects()[:contact][:snapchat] == nil
    end

    # This used to be `nil` for the stated reason that TikTok's catalogue has
    # nothing for an appointment. True, and it meant an advertiser running
    # bookings off TikTok was told nothing at all when one happened, while every
    # other destination reported it. A dark channel is not a protection.
    test "TikTok folds a booking into its lead event, as its taxonomy forces" do
      assert Destinations.dialects()[:schedule][:tiktok] == "SubmitForm"
      assert Destinations.dialects()[:lead][:tiktok] == "SubmitForm"
    end

    # And the distinction survives where an advertiser actually optimises: the
    # booking and the attendance are still two different events.
    test "but a booking and a payment stay apart on TikTok" do
      refute Destinations.dialects()[:schedule][:tiktok] ==
               Destinations.dialects()[:purchase][:tiktok]
    end

    test "X is deliberately not shipped" do
      refute :x in Enum.map(Destinations.modules(), & &1.name())

      # Its endpoint and payload are known, but it needs OAuth 1.0a signing and
      # X's own API-reference page for the conversions endpoint 404s, so there
      # is no field-level spec to build against. A guessed endpoint is worse
      # than an absent one.
    end

    test "Snapchat folds lead and registration together, as its taxonomy does" do
      assert Destinations.dialects()[:lead][:snapchat] == "SIGN_UP"
      assert Destinations.dialects()[:complete_registration][:snapchat] == "SIGN_UP"
    end
  end

  describe "dispatch" do
    setup do
      Application.put_env(:pixelex, :sites, %{
        "shop" => [
          destinations: %{
            "meta" => %{"pixel_id" => "PIX", "access_token" => "TOK"},
            "tiktok" => %{"pixel_code" => "C8", "access_token" => "TT"},
            # Configured but incomplete — must be silently skipped.
            "snapchat" => %{"pixel_id" => "SNAP"}
          }
        ]
      })

      Pixelex.Sites.reset()
      :ok
    end

    test "reaches every configured platform and skips the incomplete one" do
      capture(200, %{"code" => 0})

      results = Destinations.dispatch("shop", :purchase, event_id: "order:1")

      assert Enum.sort(Keyword.keys(results)) == [:meta, :tiktok]
      assert Enum.all?(results, fn {_p, r} -> r == :ok end)
    end

    test "copies a generic click_id into each platform's own field name" do
      capture(200, %{"code" => 0})

      Destinations.dispatch("shop", :lead,
        event_id: "lead:1",
        user_data: %{click_id: "CLICK123"}
      )

      requests =
        for _ <- 1..2 do
          assert_receive {:request, req}
          req
        end

      meta = Enum.find(requests, &(&1.url =~ "facebook.com"))
      tiktok = Enum.find(requests, &(&1.url =~ "tiktok.com"))

      assert hd(meta.body["data"])["user_data"]["fbc"] =~ "CLICK123"
      assert hd(tiktok.body["data"])["user"]["ttclid"] == "CLICK123"
    end

    # The example used to be TikTok and `:schedule`, which is no longer one: a
    # booking now folds into TikTok's `SubmitForm`, because sending nothing left
    # an advertiser running bookings off TikTok with a dark channel. The rule
    # this test is actually about is unchanged, so it moves to a platform where
    # the gap is real — Snapchat has no contact event.
    test "an event a platform has no name for simply does not go there" do
      Application.put_env(:pixelex, :sites, %{
        "quiet" => [
          destinations: %{
            "meta" => %{"pixel_id" => "PIX", "access_token" => "TOK"},
            "snapchat" => %{"pixel_id" => "SNAP", "access_token" => "SK"}
          }
        ]
      })

      Pixelex.Sites.reset()
      capture(200, %{})

      results = Destinations.dispatch("quiet", :contact, event_id: "c:1")

      assert Keyword.keys(results) == [:meta], "Snapchat has no contact event"
    end

    test "an unknown site reaches nothing" do
      assert Destinations.dispatch("nope", :purchase, event_id: "x") == []
    end

    test "credentials never come from the job, only from the site" do
      assert %{meta: %{pixel_id: "PIX", access_token: "TOK"}} = Destinations.credentials("shop")
    end

    test "unknown credential keys are dropped rather than interned as atoms" do
      key = "attacker_key_#{System.unique_integer([:positive])}"

      Application.put_env(:pixelex, :sites, %{
        "evil" => [destinations: %{"meta" => %{"pixel_id" => "P", key => "x"}}]
      })

      Pixelex.Sites.reset()

      assert Destinations.credentials("evil") == %{meta: %{pixel_id: "P"}}
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  describe "fire/3" do
    setup do
      Application.put_env(:pixelex, :sites, %{
        "shop" => [destinations: %{"meta" => %{"pixel_id" => "P", "access_token" => "T"}}]
      })

      Pixelex.Sites.reset()
      :ok
    end

    test "refuses an event outside the canonical set" do
      assert :ok = Destinations.fire("shop", :not_a_real_event, event_id: "x")
    end

    test "a refused consent decision sends nothing" do
      Application.put_env(:pixelex, :consent_gate, enabled: true)
      on_exit(fn -> Application.delete_env(:pixelex, :consent_gate) end)

      capture()

      assert :ok =
               Destinations.fire("shop", :purchase,
                 event_id: "order:1",
                 consent: %{country: "DE", decision: nil}
               )

      refute_receive {:request, _}, 200
    end

    test "GPC blocks a destination even where no banner applies" do
      capture()

      assert :ok =
               Destinations.fire("shop", :purchase,
                 event_id: "order:1",
                 consent: %{country: "EG", gpc: "1"}
               )

      refute_receive {:request, _}, 200
    end

    test "never raises, whatever it is handed" do
      assert :ok = Destinations.fire("shop", :purchase, event_id: nil, user_data: "not a map")
      assert :ok = Destinations.fire("nope", :purchase, [])
    end
  end
end
