defmodule Pixelex.Destinations.DetectTest do
  use ExUnit.Case, async: true

  alias Pixelex.Destinations.Detect

  describe "detect/1 on the snippets platforms actually hand out" do
    test "Meta" do
      snippet = """
      <script>
      !function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?
      n.callMethod.apply(n,arguments):n.queue.push(arguments)};
      }(window, document,'script','https://connect.facebook.net/en_US/fbevents.js');
      fbq('init', '1234567890123456');
      fbq('track', 'PageView');
      </script>
      """

      assert Detect.detect(snippet) == %{meta: %{pixel_id: "1234567890123456"}}
    end

    test "GA4" do
      snippet = ~s|<script async src="https://www.googletagmanager.com/gtag/js?id=G-ABC1234XYZ">|
      assert Detect.detect(snippet) == %{ga4: %{measurement_id: "G-ABC1234XYZ"}}
    end

    test "TikTok" do
      assert Detect.detect(~s|ttq.load('CQ1D2E3F4G5H6I7J8K9L');|) ==
               %{tiktok: %{pixel_code: "CQ1D2E3F4G5H6I7J8K9L"}}
    end

    test "Snapchat" do
      snippet = ~s|snaptr('init', '2f5b2c4e-9e13-4a1f-9a3c-6c2f8e1d0a77', {});|

      assert Detect.detect(snippet) ==
               %{snapchat: %{pixel_id: "2f5b2c4e-9e13-4a1f-9a3c-6c2f8e1d0a77"}}
    end

    test "Reddit" do
      assert Detect.detect(~s|rdt('init','a2_f8x9k2m1p');|) ==
               %{reddit: %{pixel_id: "a2_f8x9k2m1p"}}
    end

    test "LinkedIn's partner id, so the paste box is not silent about it" do
      assert Detect.detect(~s|_linkedin_partner_id = "1234567";|) ==
               %{linkedin: %{partner_id: "1234567"}}
    end

    test "Pinterest's tag id" do
      assert Detect.detect(~s|pintrk('load', '2612345678901');|) ==
               %{pinterest: %{tag_id: "2612345678901"}}
    end
  end

  describe "detect/1 on bare ids" do
    test "a 16-digit number is a Meta pixel" do
      assert Detect.detect("1234567890123456") == %{meta: %{pixel_id: "1234567890123456"}}
    end

    test "whitespace around a paste does not defeat it" do
      assert Detect.detect("  G-ABC1234XYZ \n") == %{ga4: %{measurement_id: "G-ABC1234XYZ"}}
    end

    test "a Meta system-user token is recognised by its prefix" do
      token = "EAA" <> String.duplicate("x", 60)
      assert Detect.detect(token) == %{meta: %{access_token: token}}
    end

    test "a bare UUID is a Snapchat pixel" do
      assert Detect.detect("2F5B2C4E-9E13-4A1F-9A3C-6C2F8E1D0A77") ==
               %{snapchat: %{pixel_id: "2F5B2C4E-9E13-4A1F-9A3C-6C2F8E1D0A77"}}
    end
  end

  describe "detect/1 declines to guess" do
    test "nothing recognisable is an empty map, not a wrong answer" do
      assert Detect.detect("hello") == %{}
      assert Detect.detect("") == %{}
      assert Detect.detect(nil) == %{}
    end

    test "an API secret has no shape, so it is never attributed to a platform" do
      assert Detect.detect("aB3xK9pQrS2tUvWxYz01Aa") == %{}
    end

    test "a snippet wins over a stray number in the same paste" do
      paste = "account 999888777666555\n<script>fbq('init', '1234567890123456');</script>"
      assert Detect.detect(paste)[:meta][:pixel_id] == "1234567890123456"
    end

    test "input is bounded" do
      assert Detect.detect(String.duplicate("x", 200_000)) == %{}
    end
  end

  describe "clean/3" do
    test "pulls the id out of a snippet pasted into a single field" do
      assert Detect.clean(:meta, :pixel_id, "<script>fbq('init', '1234567890123456');</script>") ==
               "1234567890123456"
    end

    test "leaves a value it does not recognise alone — the human knows more" do
      assert Detect.clean(:pinterest, :ad_account_id, "  549755885175 ") == "549755885175"
    end

    test "trims, always" do
      assert Detect.clean(:ga4, :measurement_id, "  G-ABC1234XYZ  ") == "G-ABC1234XYZ"
    end

    test "does not cross platforms: a Meta snippet in the GA4 field stays as typed" do
      snippet = "fbq('init', '1234567890123456')"
      assert Detect.clean(:ga4, :measurement_id, snippet) == snippet
    end

    test "nil is empty" do
      assert Detect.clean(:meta, :pixel_id, nil) == ""
    end
  end
end
