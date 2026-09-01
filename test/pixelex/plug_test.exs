defmodule Pixelex.PlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Pixelex.{Ingest, RateLimit, Sessions, Sites, Store}

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Version/17 Safari/605"

  setup do
    Application.put_env(:pixelex, :store, Store.ETS)
    Application.put_env(:pixelex, :salt_persistence, :memory)

    Application.put_env(:pixelex, :sites, %{
      "shop.test" => [domain: "shop.test", allowed_events: ~w(book_click)]
    })

    Ingest.flush()
    Store.ETS.reset()
    Sessions.reset()
    RateLimit.reset()
    Sites.reset()

    on_exit(fn ->
      Application.delete_env(:pixelex, :sites)
      Application.delete_env(:pixelex, :client_ip_header)
      Application.delete_env(:pixelex, :rate_limit)
      RateLimit.reset()
      Sessions.reset()
    end)

    :ok
  end

  defp stored do
    Ingest.flush()
    Store.ETS.all()
  end

  defp html(conn, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, "<html></html>")
  end

  defp get(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, "https://shop.test" <> path), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> Map.put(:host, "shop.test")
  end

  describe "Pixelex.Plug — server-side page views" do
    test "counts an HTML 200 with no JavaScript involved" do
      get("/pricing", [{"user-agent", @chrome}, {"referer", "https://www.google.com/search?q=x"}])
      |> Pixelex.Plug.call(Pixelex.Plug.init([]))
      |> html()

      assert [event] = stored()
      assert event.name == "px.pageview"
      assert event.pathname == "/pricing"
      assert event.site_id == "shop.test"
      assert event.render == :dead
      assert event.browser == "Safari"
      assert event.attribution["last"]["source"] == "Google"
    end

    test "ignores anything that is not a person looking at a page" do
      # JSON response
      conn(:get, "https://shop.test/api/x")
      |> Map.put(:host, "shop.test")
      |> Pixelex.Plug.call(Pixelex.Plug.init([]))
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")

      # non-GET
      conn(:post, "https://shop.test/checkout")
      |> Map.put(:host, "shop.test")
      |> Pixelex.Plug.call(Pixelex.Plug.init([]))
      |> html()

      # error response
      get("/missing") |> Pixelex.Plug.call(Pixelex.Plug.init([])) |> html(404)

      # a redirect
      get("/old") |> Pixelex.Plug.call(Pixelex.Plug.init([])) |> html(302)

      assert stored() == []
    end

    test "never counts its own ingest endpoint" do
      get("/px/e") |> Pixelex.Plug.call(Pixelex.Plug.init([])) |> html()
      assert stored() == []
    end

    test "honours :skip and :paths" do
      get("/admin/users")
      |> Pixelex.Plug.call(Pixelex.Plug.init(paths: ["/shop"]))
      |> html()

      get("/shop/item")
      |> Pixelex.Plug.call(Pixelex.Plug.init(skip: fn _conn -> true end))
      |> html()

      assert stored() == []
    end

    test "a crash while recording does not break the response" do
      # site_id resolver blows up mid-request.
      conn =
        get("/x")
        |> Pixelex.Plug.call(Pixelex.Plug.init(site_id: fn _ -> raise "boom" end))
        |> html()

      assert conn.status == 200
      assert conn.resp_body == "<html></html>"
    end

    test "the same path twice in a row counts once" do
      for _ <- 1..2 do
        get("/pricing", [{"user-agent", @chrome}])
        |> Pixelex.Plug.call(Pixelex.Plug.init([]))
        |> html()
      end

      assert length(stored()) == 1,
             "a dead render followed by its connected render is one page view"
    end
  end

  describe "Pixelex.Plug.Context" do
    test "reads the peer address by default" do
      conn = %{conn(:get, "/") | remote_ip: {41, 33, 1, 9}}
      assert Pixelex.Plug.Context.client_ip(conn) == "41.33.1.9"
    end

    test "prefers a configured proxy header and takes the left-most entry" do
      Application.put_env(:pixelex, :client_ip_header, "x-forwarded-for")

      conn =
        %{conn(:get, "/") | remote_ip: {10, 0, 0, 1}}
        |> put_req_header("x-forwarded-for", "197.55.10.3, 10.0.0.1, 172.16.0.5")

      assert Pixelex.Plug.Context.client_ip(conn) == "197.55.10.3"
    end

    test "falls back to the peer address when the configured header is absent" do
      Application.put_env(:pixelex, :client_ip_header, "fly-client-ip")
      conn = %{conn(:get, "/") | remote_ip: {41, 33, 1, 9}}
      assert Pixelex.Plug.Context.client_ip(conn) == "41.33.1.9"
    end

    test "picks up country from whichever CDN header is present" do
      for header <- ~w(cf-ipcountry fly-client-country x-vercel-ip-country) do
        ctx =
          conn(:get, "/")
          |> put_req_header(header, "EG")
          |> Pixelex.Plug.Context.build(site_id: "s")

        assert ctx.country == "EG", "#{header} was not read"
      end
    end

    test "collects the privacy headers into the consent signals" do
      ctx =
        conn(:get, "/")
        |> put_req_header("sec-gpc", "1")
        |> put_req_header("dnt", "1")
        |> Pixelex.Plug.Context.build(site_id: "s")

      assert ctx.consent.gpc == "1"
      assert ctx.consent.dnt == "1"
    end
  end

  describe "Pixelex.Plug.Ingest" do
    defp post(payload, headers \\ [{"user-agent", @chrome}]) do
      Enum.reduce(headers, conn(:post, "/e", Jason.encode!(payload)), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> put_req_header("content-type", "application/json")
      |> Map.put(:host, "shop.test")
      |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))
    end

    test "records an allowlisted event and answers 204" do
      conn = post(%{"s" => "shop.test", "n" => "book_click", "u" => "https://shop.test/dr/1"})

      assert conn.status == 204
      assert conn.resp_body == ""

      assert [event] = stored()
      assert event.name == "book_click"
      assert event.pathname == "/dr/1"
      assert event.render == :client
    end

    test "answers 204 identically for everything it drops" do
      cases = [
        {%{"s" => "shop.test", "n" => "not_in_allowlist"}, "unknown event name"},
        {%{"s" => "no-such-site", "n" => "book_click"}, "unknown site"},
        {%{"s" => "shop.test", "n" => String.duplicate("x", 200)}, "absurd event name"}
      ]

      for {payload, description} <- cases do
        conn = post(payload)

        assert conn.status == 204, "#{description} should still be 204"
        assert conn.resp_body == "", "#{description} should reveal nothing"
      end

      assert stored() == [], "nothing in that list should have been recorded"
    end

    test "a payload with no site falls back to the request host" do
      # Deliberate: a single-tenant app should not have to put its own site id
      # in every beacon, and the Host header already says which site this is.
      assert post(%{"n" => "book_click"}).status == 204
      assert [%{site_id: "shop.test", name: "book_click"}] = stored()
    end

    test "an empty payload is a page view for the requesting host" do
      assert post(%{}).status == 204
      assert [%{name: "px.pageview", site_id: "shop.test"}] = stored()
    end

    test "a malformed body is a 204, not a 500" do
      conn =
        conn(:post, "/e", "{not json at all")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "shop.test")
        |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))

      assert conn.status == 204
    end

    test "keeps the client's own timestamp" do
      ms = System.system_time(:millisecond) - 4_000
      post(%{"s" => "shop.test", "n" => "book_click", "t" => ms})

      assert [event] = stored()
      assert DateTime.to_unix(event.client_ts, :millisecond) == ms
    end

    test "stores custom properties" do
      post(%{"s" => "shop.test", "n" => "book_click", "p" => %{"doctor" => "a", "slot" => 3}})

      assert [event] = stored()
      assert event.props == %{"doctor" => "a", "slot" => 3}
    end

    test "rate limits per IP and still answers 204" do
      Application.put_env(:pixelex, :rate_limit, {3, 60_000})

      for _ <- 1..6 do
        assert post(%{"s" => "shop.test", "n" => "book_click"}).status == 204
      end

      assert length(stored()) <= 3, "the limiter must actually bound writes"
    end

    test "crawlers are dropped even with a valid payload" do
      post(%{"s" => "shop.test", "n" => "book_click"}, [
        {"user-agent", "Mozilla/5.0 (compatible; AhrefsBot/7.0)"}
      ])

      assert stored() == []
    end

    test "GET /px.gif returns a real 1x1 GIF and records" do
      conn =
        conn(:get, "/px.gif?s=shop.test&n=book_click&u=https%3A%2F%2Fshop.test%2Fx")
        |> put_req_header("user-agent", @chrome)
        |> Map.put(:host, "shop.test")
        |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/gif; charset=utf-8"]
      assert <<"GIF89a", _::binary>> = conn.resp_body
      assert byte_size(conn.resp_body) == 42
      assert ["no-store" <> _] = Plug.Conn.get_resp_header(conn, "cache-control")

      assert [event] = stored()
      assert event.name == "book_click"
    end

    test "px.pageview never needs allowlisting" do
      post(%{"s" => "shop.test", "n" => "px.pageview", "u" => "https://shop.test/a"})
      assert [%{name: "px.pageview"}] = stored()
    end

    test "serves the tracker from the host's own origin" do
      conn =
        conn(:get, "/pixelex.js")
        |> Map.put(:host, "shop.test")
        |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))

      assert conn.status == 200
      assert ["application/javascript" <> _] = get_resp_header(conn, "content-type")
      assert [etag] = get_resp_header(conn, "etag")
      assert byte_size(conn.resp_body) < 8_000, "the tracker must stay small"
      assert conn.resp_body =~ "pixelex"

      # Second request with the etag is a 304.
      revalidated =
        conn(:get, "/pixelex.js")
        |> put_req_header("if-none-match", etag)
        |> Map.put(:host, "shop.test")
        |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))

      assert revalidated.status == 304
      assert revalidated.resp_body == ""
    end

    test "an unknown method or path is a 404" do
      conn =
        conn(:put, "/e")
        |> Map.put(:host, "shop.test")
        |> Pixelex.Plug.Ingest.call(Pixelex.Plug.Ingest.init([]))

      assert conn.status == 404
    end
  end

  describe "Pixelex.Sites" do
    test "config-declared sites need no database" do
      assert %Sites{id: "shop.test", domain: "shop.test"} = Sites.get("shop.test")
      assert Sites.allowed_event?(Sites.get("shop.test"), "book_click")
      refute Sites.allowed_event?(Sites.get("shop.test"), "anything_else")
    end

    test "an unknown site is nil, not an auto-created tenant" do
      assert Sites.get("never-heard-of-it") == nil
      refute Sites.allowed_event?(nil, "book_click")
    end

    test "allow_any_event opts a trusted site out of the allowlist" do
      Application.put_env(:pixelex, :sites, %{"open" => [allow_any_event: true]})
      assert Sites.allowed_event?(Sites.get("open"), "whatever_it_likes")
    end
  end

  describe "Pixelex.RateLimit" do
    test "allows up to the limit then denies" do
      key = "t:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimit.hit(key, 60_000, 2)
      assert {:allow, 2} = RateLimit.hit(key, 60_000, 2)
      assert {:deny, 2} = RateLimit.hit(key, 60_000, 2)
    end

    test "counts each key separately" do
      a = "a:#{System.unique_integer([:positive])}"
      b = "b:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimit.hit(a, 60_000, 1)
      assert {:deny, 1} = RateLimit.hit(a, 60_000, 1)
      assert {:allow, 1} = RateLimit.hit(b, 60_000, 1)
    end

    test "a new window starts a new count" do
      key = "w:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimit.hit(key, 20, 1)
      assert {:deny, 1} = RateLimit.hit(key, 20, 1)
      Process.sleep(45)
      assert {:allow, 1} = RateLimit.hit(key, 20, 1)
    end

    test "sweeping drops expired windows" do
      RateLimit.hit("s:#{System.unique_integer([:positive])}", 20, 5)
      Process.sleep(45)
      assert RateLimit.sweep(20) >= 1
    end
  end
end
