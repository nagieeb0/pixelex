defmodule Pixelex.PixelsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Pixelex.{Pixels, Sites}

  @site "pixels.test"

  setup do
    Sites.reset()
    on_exit(fn -> Application.delete_env(:pixelex, :sites) end)
    :ok
  end

  defp configure(destinations) do
    Application.put_env(:pixelex, :sites, %{@site => [destinations: destinations]})
    Sites.reset()
  end

  defp render(assigns) do
    opts = Map.merge(%{site_id: @site, consent: %{}, nonce: nil}, assigns)
    render_component(&Pixels.tags/1, Map.to_list(opts))
  end

  describe "ids/1" do
    test "reads each platform's browser id from the stored credentials" do
      configure(%{
        "meta" => %{"pixel_id" => "1234567890123456"},
        "ga4" => %{"measurement_id" => "G-ABC1234XYZ"},
        "tiktok" => %{"pixel_code" => "CQ1D2E3F4G5H6I7J8K9L"}
      })

      assert Pixels.ids(@site) == %{
               meta: "1234567890123456",
               ga4: "G-ABC1234XYZ",
               tiktok: "CQ1D2E3F4G5H6I7J8K9L"
             }
    end

    # Pinterest authenticates the server API with an ad account id and loads
    # its tag with a different number; using one for the other silently loads
    # nothing.
    test "Pinterest's browser id is the tag id, not the ad account id" do
      configure(%{"pinterest" => %{"ad_account_id" => "549755885175"}})
      assert Pixels.ids(@site) == %{}

      configure(%{
        "pinterest" => %{"ad_account_id" => "549755885175", "tag_id" => "2612345678901"}
      })

      assert Pixels.ids(@site) == %{pinterest: "2612345678901"}
    end

    test "an unknown site has no ids" do
      assert Pixels.ids("nope.test") == %{}
      assert Pixels.ids(nil) == %{}
    end
  end

  describe "tags/1" do
    test "renders nothing for a site with no ids" do
      configure(%{})
      assert render(%{}) |> String.trim() == ""
    end

    test "a Meta id produces an initialised pixel and a PageView" do
      configure(%{"meta" => %{"pixel_id" => "1234567890123456"}})
      html = render(%{})

      assert html =~ "connect.facebook.net/en_US/fbevents.js"
      assert html =~ "fbq('init','1234567890123456')"
      assert html =~ "fbq('track','PageView')"
    end

    test "GA4 gets its external loader as well as the inline config" do
      configure(%{"ga4" => %{"measurement_id" => "G-ABC1234XYZ"}})
      html = render(%{})

      assert html =~ ~s(src="https://www.googletagmanager.com/gtag/js?id=G-ABC1234XYZ")
      assert html =~ "gtag('config','G-ABC1234XYZ')"
    end

    test "several platforms render together" do
      configure(%{
        "meta" => %{"pixel_id" => "1234567890123456"},
        "snapchat" => %{"pixel_id" => "2f5b2c4e-9e13-4a1f-9a3c-6c2f8e1d0a77"},
        "reddit" => %{"pixel_id" => "a2_f8x9k2m1p"}
      })

      html = render(%{})

      assert html =~ "fbq('init','1234567890123456')"
      assert html =~ "snaptr('init','2f5b2c4e-9e13-4a1f-9a3c-6c2f8e1d0a77')"
      assert html =~ "rdt('init','a2_f8x9k2m1p')"
    end

    test "an access token alone renders nothing — that is the server leg" do
      configure(%{"meta" => %{"access_token" => "EAAtoken"}})
      assert render(%{}) |> String.trim() == ""
    end
  end

  # The id is written into JavaScript, so this is a script-injection boundary.
  describe "tags/1 refuses an unsafe id" do
    for {name, id} <- [
          {"a closing script tag", "1234'</script><script>alert(1)//"},
          {"a quote break-out", "123',{});alert(1);fbq('init','9"},
          {"a backslash", "123\\u0027"},
          {"whitespace", "123 456"},
          {"an angle bracket", "12<3"},
          {"something far too long", String.duplicate("1", 65)}
        ] do
      test "skips #{name}" do
        configure(%{"meta" => %{"pixel_id" => unquote(id)}})

        assert Pixels.ids(@site) == %{}
        assert render(%{}) |> String.trim() == ""
      end
    end

    test "one bad id does not take a good one down with it" do
      configure(%{
        "meta" => %{"pixel_id" => "'); alert(1); ('"},
        "ga4" => %{"measurement_id" => "G-ABC1234XYZ"}
      })

      html = render(%{})

      refute html =~ "alert(1)"
      assert html =~ "gtag('config','G-ABC1234XYZ')"
    end
  end

  describe "consent" do
    setup do
      configure(%{"meta" => %{"pixel_id" => "1234567890123456"}})
      :ok
    end

    test "renders when no visitor signals are supplied" do
      assert render(%{}) =~ "fbq('init'"
    end

    test "renders for a granted decision inside the gated area" do
      assert render(%{consent: %{country: "DE", decision: "granted"}}) =~ "fbq('init'"
    end

    test "renders for an undecided visitor while the geo gate is off (the default)" do
      assert render(%{consent: %{country: "DE", decision: nil}}) =~ "fbq('init'"
    end

    test "renders nothing for an undecided visitor once the geo gate is on" do
      Application.put_env(:pixelex, :consent_gate, enabled: true)
      on_exit(fn -> Application.delete_env(:pixelex, :consent_gate) end)

      refute render(%{consent: %{country: "DE", decision: nil}}) =~ "fbq('init'"
      assert render(%{consent: %{country: "DE", decision: "granted"}}) =~ "fbq('init'"
      assert render(%{consent: %{country: "EG", decision: nil}}) =~ "fbq('init'"
    end

    test "renders nothing under Global Privacy Control" do
      refute render(%{consent: %{country: "US", gpc: "1"}}) =~ "fbq('init'"
    end
  end

  describe "CSP nonce" do
    setup do
      configure(%{"meta" => %{"pixel_id" => "1234567890123456"}})
      :ok
    end

    test "lands on the inline script" do
      assert render(%{nonce: "r4nd0mNonce=="}) =~ ~s(<script nonce="r4nd0mNonce==">)
    end

    test "a nonce that is not a nonce is dropped rather than injected" do
      html = render(%{nonce: ~S[x" onload="alert(1)]})

      refute html =~ "onload"
      assert html =~ "fbq('init'"
    end
  end
end
