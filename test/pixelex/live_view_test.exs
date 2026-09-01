defmodule Pixelex.LiveViewTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pixelex.{Ingest, Sessions, Store}

  @endpoint Pixelex.Test.Endpoint
  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Version/17 Safari/605"

  setup do
    Application.put_env(:pixelex, :store, Store.ETS)
    Application.put_env(:pixelex, :salt_persistence, :memory)
    # The realistic deployment: a proxy in front, and both the plug and the
    # socket reading the visitor's address from the same header. Without this
    # they disagree and every page load counts twice.
    Application.put_env(:pixelex, :client_ip_header, "x-forwarded-for")
    Application.put_env(:pixelex, :site_id, "live.test")

    Application.put_env(:pixelex, :sites, %{
      "live.test" => [allow_any_event: true],
      "dash.test" => [allow_any_event: true]
    })

    Ingest.flush()
    Store.ETS.reset()
    Sessions.reset()
    Pixelex.Sites.reset()

    on_exit(fn ->
      Application.delete_env(:pixelex, :sites)
      Application.delete_env(:pixelex, :client_ip_header)
      Application.delete_env(:pixelex, :site_id)
    end)

    %{conn: visitor()}
  end

  defp visitor(ip \\ "197.55.10.3") do
    build_conn()
    |> Plug.Conn.put_req_header("user-agent", @chrome)
    |> Plug.Conn.put_req_header("x-forwarded-for", ip)
  end

  defp stored do
    Ingest.flush()
    Store.ETS.all()
  end

  defp pageviews, do: Enum.filter(stored(), &(&1.name == "px.pageview"))

  describe "the dead render and the connected render are one page view" do
    test "a full page load counts once, not twice", %{conn: conn} do
      {:ok, _live, html} = live(conn, "/live")

      assert html =~ "page"

      views = pageviews()

      assert length(views) == 1,
             """
             mount/3 and handle_params/3 both run twice on a page load — once for
             the dead render and once when the socket connects. Counting both
             doubles every visitor; counting only the connected one loses
             crawlers and no-JS clients. Got #{length(views)}.
             """
    end

    test "the dead render is what gets recorded, and it is tagged" do
      # The dead render happens first and is the one that survives; the
      # connected render arrives inside the dedupe window and is dropped.
      {:ok, _live, _html} = live(visitor(), "/live")

      assert [view] = pageviews()
      assert view.render in [:dead, :connected]
      assert view.pathname == "/live"
      assert view.site_id == "live.test"
    end
  end

  describe "live navigation" do
    test "a live_patch to a new path is a new page view", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/live")
      assert length(pageviews()) == 1

      live |> element("button", "patch") |> render_click()

      views = pageviews()
      assert length(views) == 2, "live_patch never touches a Plug, so this is the only signal"
      assert Enum.any?(views, &(&1.url =~ "tab=b"))
    end

    test "patching back to a path already seen counts again", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/live")
      live |> element("button", "patch") |> render_click()
      before = length(pageviews())

      render_patch(live, "/live")

      assert length(pageviews()) == before + 1,
             "a real navigation back is a real page view; only the render pair is deduplicated"
    end
  end

  describe "reconnects" do
    # Deduplication normally hides the connected render behind the plug's dead
    # render, which would make both cases below look identical. Switching it
    # off isolates the rejoin guard itself: the question is whether the
    # connected render fires at all, not whether it survives the dedupe.
    setup do
      Application.put_env(:pixelex, :pageview_dedupe_ms, 0)
      on_exit(fn -> Application.delete_env(:pixelex, :pageview_dedupe_ms) end)
      :ok
    end

    test "the rejoin signal is read from _mounts" do
      # Asserted directly, because Phoenix.LiveViewTest sets `_mounts` itself
      # and ignores put_connect_params/2 for that key — a simulated mount
      # always reports 0 and can never reach this branch.
      refute Pixelex.LiveView.rejoin?(%{"_mounts" => 0}), "a first mount is a visit"
      refute Pixelex.LiveView.rejoin?(%{}), "no signal means treat it as a visit"
      refute Pixelex.LiveView.rejoin?(%{"_mounts" => "3"}), "a non-integer is not a rejoin"

      assert Pixelex.LiveView.rejoin?(%{"_mounts" => 1})
      assert Pixelex.LiveView.rejoin?(%{"_mounts" => 47})
    end

    test "a first mount does count" do
      {:ok, _live, _html} =
        visitor("197.55.10.77")
        |> put_connect_params(%{"_mounts" => 0})
        |> live("/live")

      renders = pageviews() |> Enum.map(& &1.render) |> Enum.sort()

      assert renders == [:connected, :dead],
             "with dedupe off, a genuine first mount produces both renders"
    end
  end

  describe "nested LiveViews" do
    test "a view not mounted at the router does not blow up on the hook" do
      # attach_hook/4 on :handle_params raises for a LiveView rendered with
      # live_render/3. Analytics must never be the reason a page 500s.
      assert {:ok, _live, html} =
               visitor()
               |> live_isolated(Pixelex.Test.NestedLive)

      assert html =~ "nested"
    end
  end

  describe "events from inside a LiveView" do
    test "track/3 records with the page attached", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/live")

      live |> element("button", "convert") |> render_click()

      assert conversion = Enum.find(stored(), &(&1.name == "booking_completed"))
      assert conversion.props == %{"value" => 1}
      assert conversion.url =~ "/live"
      assert conversion.session_id == hd(pageviews()).session_id
    end
  end

  describe "what the socket cannot see on its own" do
    test "the referrer survives the upgrade from HTTP to WebSocket" do
      # A WebSocket carries no Referer header — it is sent once, on the initial
      # request. Without Pixelex.Plug.Session stashing it, every LiveView visit
      # after the first render is attributed to direct traffic.
      conn =
        Plug.Conn.put_req_header(visitor(), "referer", "https://www.google.com/search?q=dentist")

      {:ok, _live, _html} = live(conn, "/live")

      assert [view] = pageviews()
      assert view.attribution["last"]["source"] == "Google"
      assert view.attribution["last"]["medium"] == "organic_search"
    end

    test "the country header stashed by the plug reaches the socket" do
      conn = Plug.Conn.put_req_header(visitor(), "cf-ipcountry", "EG")

      {:ok, _live, _html} = live(conn, "/live")

      assert [%{country: "EG"}] = pageviews()
    end

    test "Sec-GPC blocks a LiveView page view too" do
      conn = Plug.Conn.put_req_header(visitor(), "sec-gpc", "1")

      {:ok, _live, _html} = live(conn, "/live")

      assert pageviews() == []
    end
  end

  describe "the dashboard" do
    setup %{conn: conn} do
      # Real traffic for it to render.
      for path <- ~w(/ /pricing /pricing /about) do
        Pixelex.page(%{
          site_id: "dash.test",
          ip: "197.55.10.#{:rand.uniform(200)}",
          user_agent: @chrome,
          url: "https://dash.test#{path}?gclid=Cj0",
          render: :server
        })
      end

      Pixelex.track(
        %{site_id: "dash.test", ip: "197.55.10.9", user_agent: @chrome, render: :server},
        "book_click"
      )

      Ingest.flush()
      %{conn: conn}
    end

    @tag :integration
    test "renders traffic without a database error", %{conn: conn} do
      Application.put_env(:pixelex, :store, Store.Postgres)
      on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)

      {:ok, _live, html} = live(conn, "/analytics")

      assert html =~ "Analytics"
      assert html =~ "dash.test"
      assert html =~ "Page views"
      assert html =~ "Funnel"

      refute html =~ "Could not read the event log"
    end

    @tag :integration
    test "labels the visitor count for what it is", %{conn: conn} do
      Application.put_env(:pixelex, :store, Store.Postgres)
      on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)

      {:ok, _live, html} = live(conn, "/analytics")

      assert html =~ "daily sum",
             "a tile labelled just `Visitors` would be a number the salt rotation makes untrue"
    end

    @tag :integration
    test "switching the range re-queries", %{conn: conn} do
      Application.put_env(:pixelex, :store, Store.Postgres)
      on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)

      {:ok, live, _html} = live(conn, "/analytics")

      html = live |> element("button", "30d") |> render_click()
      assert html =~ "Analytics"
    end

    @tag :integration
    test "the funnel builder runs and reports", %{conn: conn} do
      Application.put_env(:pixelex, :store, Store.Postgres)
      on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)

      {:ok, live, _html} = live(conn, "/analytics")

      html =
        live
        |> form("form", %{"steps" => "px.pageview\nbook_click"})
        |> render_submit()

      assert html =~ "Overall conversion"
    end

    @tag :integration
    test "a bad funnel step reports instead of crashing", %{conn: conn} do
      Application.put_env(:pixelex, :store, Store.Postgres)
      on_exit(fn -> Application.put_env(:pixelex, :store, Store.ETS) end)

      {:ok, live, _html} = live(conn, "/analytics")

      html =
        live
        |> form("form", %{"steps" => Enum.map_join(1..15, "\n", &"step#{&1}")})
        |> render_submit()

      # Capped at 10 steps, so 15 is refused — as a message, not a 500.
      assert html =~ "Analytics"
    end
  end
end
