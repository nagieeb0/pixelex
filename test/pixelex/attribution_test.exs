defmodule Pixelex.AttributionTest do
  use ExUnit.Case, async: true

  doctest Pixelex.Attribution

  alias Pixelex.Attribution
  alias Pixelex.Attribution.ClickIds

  defp touch(url, referrer \\ nil), do: Attribution.touch(url, referrer, hostname: "shop.test")

  describe "click ids — attribution with no UTM at all" do
    test "recognises the major networks by their own click parameter" do
      cases = [
        {"fbclid=IwAR9x", "facebook", "paid_social"},
        {"gclid=Cj0KCQ", "google", "paid_search"},
        {"gbraid=abc", "google", "paid_search"},
        {"wbraid=abc", "google", "paid_search"},
        {"msclkid=m1", "bing", "paid_search"},
        {"ttclid=t1", "tiktok", "paid_social"},
        {"twclid=w1", "x", "paid_social"},
        {"li_fat_id=l1", "linkedin", "paid_social"},
        {"epik=p1", "pinterest", "paid_social"},
        {"sccid=s1", "snapchat", "paid_social"},
        {"rdt_cid=r1", "reddit", "paid_social"},
        {"yclid=y1", "yandex", "paid_search"},
        {"tblci=tb1", "taboola", "native"},
        {"obOrigUrl=o1", "outbrain", "native"},
        {"irclickid=i1", "impact", "affiliate"},
        {"igshid=ig1", "instagram", "social"}
      ]

      for {query, network, medium} <- cases do
        t = touch("https://shop.test/p?#{query}")

        assert t.network == network, "#{query} should attribute to #{network}, got #{t.network}"
        assert t.medium == medium, "#{query} should be #{medium}, got #{t.medium}"
        assert t.click_id != nil
      end
    end

    test "keeps the click id and the parameter it came from" do
      t = touch("https://shop.test/p?fbclid=IwAR9x")
      assert t.click_id == "IwAR9x"
      assert t.click_id_param == "fbclid"
    end

    test "a paid-search click wins over a stale social id on the same URL" do
      # Real shape: someone clicks a Google ad to a page whose own link still
      # carries an igshid from an earlier Instagram share. The click that was
      # paid for is the one that gets credit.
      t = touch("https://shop.test/p?igshid=old&gclid=Cj0")
      assert t.network == "google"
      assert t.click_id == "Cj0"
    end

    test "an empty click id is not a click id" do
      t = touch("https://shop.test/p?fbclid=")
      assert t.source == "direct"
    end

    test "every parameter in the table resolves to a network and a medium" do
      for {param, {network, medium}} <- ClickIds.all() do
        assert is_binary(network) and network != "", "#{param} has no network"
        assert is_binary(medium) and medium != "", "#{param} has no medium"
      end
    end
  end

  describe "utm parameters" do
    test "are read when present" do
      t =
        touch(
          "https://shop.test/p?utm_source=newsletter&utm_medium=email" <>
            "&utm_campaign=ramadan&utm_term=whitening&utm_content=hero"
        )

      assert t.source == "newsletter"
      assert t.medium == "email"
      assert t.campaign == "ramadan"
      assert t.term == "whitening"
      assert t.content == "hero"
    end

    test "the short ref parameter works like utm_source" do
      t = touch("https://shop.test/p?ref=producthunt")
      assert t.source == "producthunt"
      assert t.medium == "referral"
    end

    test "a click id outranks utm_source" do
      # A forged gclid is not a thing; a stale utm_source copied between links
      # is an everyday occurrence.
      t = touch("https://shop.test/p?utm_source=old-campaign&fbclid=IwAR9")
      assert t.source == "facebook"
    end

    test "campaign detail still rides along beside a click id" do
      t = touch("https://shop.test/p?gclid=Cj0&utm_campaign=ramadan&utm_content=variant-b")

      assert t.network == "google"
      assert t.click_id == "Cj0"
      assert t.campaign == "ramadan"
      assert t.content == "variant-b"
    end
  end

  describe "referrer classification" do
    @describetag :ref_inspector

    test "organic search is identified and the query term recovered" do
      t = touch("https://shop.test/p", "https://www.google.com/search?q=dental+clinic+cairo")

      assert t.source == "Google"
      assert t.medium == "organic_search"
      assert t.term == "dental clinic cairo"
    end

    test "social networks are identified, including link-shortener hosts" do
      assert %{source: "Facebook", medium: "social"} =
               touch("https://shop.test/p", "https://www.facebook.com/")

      assert %{source: "Twitter", medium: "social"} =
               touch("https://shop.test/p", "https://t.co/abc")

      assert %{source: "Instagram", medium: "social"} =
               touch("https://shop.test/p", "https://www.instagram.com/")

      # l.facebook.com is the app's outbound redirector, not a different site.
      assert %{source: "Facebook"} = touch("https://shop.test/p", "https://l.facebook.com/")
    end

    test "webmail is email, not referral" do
      assert %{source: "Gmail", medium: "email"} =
               touch("https://shop.test/p", "https://mail.google.com/")
    end

    test "an unrecognised site falls back to its hostname as the source" do
      t = touch("https://shop.test/p", "https://some-blog.example/post")
      assert t.source == "some-blog.example"
      assert t.medium == "referral"
    end
  end

  describe "self-referrals" do
    test "a link from the site's own pages is internal, not a referral" do
      t = touch("https://shop.test/b", "https://shop.test/a")
      assert t.medium == "internal"
      assert Attribution.direct?(t)
    end

    test "www and subdomains count as the same site" do
      for referrer <- [
            "https://www.shop.test/a",
            "https://app.shop.test/a",
            "https://SHOP.TEST/a"
          ] do
        assert touch("https://shop.test/b", referrer).medium == "internal",
               "#{referrer} should be internal — otherwise a site's top traffic source is itself"
      end
    end

    test "a lookalike domain is not the same site" do
      assert touch("https://shop.test/b", "https://notshop.test/a").medium == "referral"
      assert touch("https://shop.test/b", "https://shop.test.evil.example/a").medium == "referral"
    end
  end

  describe "direct and malformed input" do
    test "no referrer and no parameters is direct" do
      t = touch("https://shop.test/p")
      assert t.source == "direct"
      assert t.medium == "none"
      assert Attribution.direct?(t)
    end

    test "nil, empty and garbage inputs do not raise" do
      for {url, ref} <- [
            {nil, nil},
            {"", ""},
            {"not a url", "also not a url"},
            {"https://shop.test/p?%%%", "://"},
            {"https://shop.test/p", "   "}
          ] do
        assert %Attribution{} = Attribution.touch(url, ref, hostname: "shop.test")
      end
    end

    test "works with no hostname configured" do
      assert %Attribution{medium: "referral"} =
               Attribution.touch("https://shop.test/p", "https://other.test/a")
    end
  end

  describe "first and last touch" do
    test "first touch is written once and never overwritten" do
      first = touch("https://shop.test/p?fbclid=IwAR9")
      later = touch("https://shop.test/p?gclid=Cj0")

      merged = nil |> Attribution.merge(first) |> Attribution.merge(later)

      assert merged["first"]["network"] == "facebook"
      assert merged["last"]["network"] == "google"
    end

    test "a direct visit does not erase the campaign that earned it" do
      paid = touch("https://shop.test/p?fbclid=IwAR9")
      direct = touch("https://shop.test/p")

      merged = nil |> Attribution.merge(paid) |> Attribution.merge(direct)

      assert merged["last"]["network"] == "facebook",
             "someone typing the URL a day later did not become the source of the conversion"
    end

    test "an internal click does not overwrite last touch either" do
      paid = touch("https://shop.test/p?gclid=Cj0")
      internal = touch("https://shop.test/b", "https://shop.test/a")

      merged = nil |> Attribution.merge(paid) |> Attribution.merge(internal)
      assert merged["last"]["network"] == "google"
    end

    test "the first touch of a direct visitor is still recorded" do
      merged = Attribution.merge(nil, touch("https://shop.test/p"))
      assert merged["first"]["source"] == "direct"
      assert merged["last"]["source"] == "direct"
    end

    test "the merged map is JSON-safe and drops empty fields" do
      merged = Attribution.merge(nil, touch("https://shop.test/p?fbclid=IwAR9"))

      assert {:ok, _} = Jason.encode(merged)
      refute Map.has_key?(merged["first"], "campaign")
      refute Map.has_key?(merged["first"], "term")
    end
  end

  describe "degraded mode" do
    test "reports which classifier is active" do
      assert Attribution.classifier() in [:ref_inspector, :hostname]
    end
  end
end
