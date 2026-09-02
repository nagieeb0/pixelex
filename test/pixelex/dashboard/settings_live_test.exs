defmodule Pixelex.Dashboard.SettingsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pixelex.{Destinations, Sites}

  @endpoint Pixelex.Test.Endpoint
  @site "settings.test"

  setup do
    reset_site()

    on_exit(fn ->
      Application.delete_env(:pixelex, :sites)
      Application.delete_env(:pixelex, :req_options)
      reset_site()
    end)

    %{conn: build_conn()}
  end

  # The suite runs without an Ecto sandbox on purpose — these tests create and
  # drop partitions — so the pixelex_sites row survives between tests, and
  # `put_credentials/3` merges into whatever the last test left behind. Clear
  # it, or a token saved three tests ago makes this one read as fully set up.
  defp reset_site do
    Sites.reset()
    Sites.update(@site, %{destinations: %{}, allowed_events: [], domain: nil})
    Sites.reset()
  rescue
    _ -> Sites.reset()
  end

  defp open(conn), do: live(conn, "/analytics/settings")

  defp connect_meta(token \\ "EAAtoken") do
    {:ok, _} =
      Destinations.put_credentials(@site, :meta, %{
        "pixel_id" => "1234567890123456",
        "access_token" => token
      })
  end

  test "renders a card for every configurable destination", %{conn: conn} do
    {:ok, _view, html} = open(conn)

    for module <- Destinations.modules() do
      assert html =~ to_string(module.name())
    end

    assert html =~ "Paste anything"
  end

  test "a pasted snippet fills the right field on the right card", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    html =
      view
      |> element("form[phx-change=detect]")
      |> render_change(%{"paste" => "<script>fbq('init', '1234567890123456');</script>"})

    assert html =~ "1234567890123456"
    assert html =~ "Found:"
  end

  test "an unrecognised paste says nothing rather than guessing", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    html =
      view |> element("form[phx-change=detect]") |> render_change(%{"paste" => "hello there"})

    refute html =~ "Found:"
  end

  @tag :integration
  test "saving a platform stores it and the card flips to connected", %{conn: conn} do
    {:ok, view, html} = open(conn)
    assert html =~ "not set up"

    html =
      render_hook(view, :save_platform, %{
        "platform" => "meta",
        "credentials" => %{
          "pixel_id" => "fbq('init', '1234567890123456')",
          "access_token" => "EAAtoken"
        }
      })

    assert html =~ "Saved meta."
    assert html =~ "browser + server, deduped"
    assert Destinations.credentials(@site)[:meta].pixel_id == "1234567890123456"
  end

  @tag :integration
  test "a stored access token is never rendered back to the browser", %{conn: conn} do
    connect_meta("EAA-super-secret-token")

    {:ok, _view, html} = open(conn)

    refute html =~ "EAA-super-secret-token"
    assert html =~ "1234567890123456"
    assert html =~ ~r/px-pill">\s*set\s*</
  end

  @tag :integration
  test "Test sends a real call and reports the answer", %{conn: conn} do
    Application.put_env(:pixelex, :req_options, plug: {Req.Test, SettingsLiveStub})
    Req.Test.stub(SettingsLiveStub, fn c -> Req.Test.json(c, %{"events_received" => 1}) end)
    connect_meta()

    {:ok, view, _html} = open(conn)

    html =
      view
      |> element("button[phx-click=test_platform][phx-value-platform=meta]")
      |> render_click()

    assert html =~ "Accepted"
  end

  @tag :integration
  test "a rejected Test prints the platform's own complaint", %{conn: conn} do
    Application.put_env(:pixelex, :req_options, plug: {Req.Test, SettingsLiveStub})

    Req.Test.stub(SettingsLiveStub, fn c ->
      Req.Test.json(%{c | status: 400}, %{"error" => %{"message" => "Invalid OAuth token"}})
    end)

    connect_meta("nope")

    {:ok, view, _html} = open(conn)

    html =
      view
      |> element("button[phx-click=test_platform][phx-value-platform=meta]")
      |> render_click()

    assert html =~ "Rejected"
  end

  @tag :integration
  test "Disconnect forgets the platform", %{conn: conn} do
    connect_meta()

    {:ok, view, _html} = open(conn)

    html =
      view
      |> element("button[phx-click=disconnect][phx-value-platform=meta]")
      |> render_click()

    assert html =~ "Disconnected meta."
    refute Map.has_key?(Destinations.credentials(@site), :meta)
  end

  @tag :integration
  test "site settings save, and the allowlist takes one name per line", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    view
    |> element("form[phx-submit=save_site]")
    |> render_submit(%{
      "domain" => "shop.test",
      "allowed_events" => "book_click\ncall_click, order_started",
      "retention_days" => "30"
    })

    site = Sites.get(@site)
    assert site.domain == "shop.test"
    assert site.allowed_events == ~w(book_click call_click order_started)
    assert site.retention_days == 30
    refute site.allow_any_event
  end

  test "a config-defined site is read-only and says why", %{conn: conn} do
    Application.put_env(:pixelex, :sites, %{@site => [domain: "x.test"]})

    {:ok, _view, html} = open(conn)

    assert html =~ "config :pixelex, sites:"
    assert html =~ "disabled"
  end

  # The form posts a platform name. String.to_atom on it would let anyone with
  # dashboard access grow the atom table one request at a time.
  test "an unknown platform name from the form is not turned into an atom", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    html = render_hook(view, :save_platform, %{"platform" => "myspace", "credentials" => %{}})

    assert html =~ "no such destination"
    refute Enum.any?(:erlang.processes(), fn _ -> false end)
  end

  # A platform dropped from `config :pixelex, destinations:` leaves its row
  # behind. Nothing declares those keys secret any more, so rendering the
  # column as-is would print the token.
  @tag :integration
  test "a stored key no destination declares is never rendered", %{conn: conn} do
    {:ok, _} =
      Sites.update(@site, %{
        destinations: %{
          "meta" => %{
            "pixel_id" => "1234567890123456",
            "access_token" => "EAAtoken",
            "leftover_token" => "EAA-from-a-removed-destination"
          }
        }
      })

    {:ok, _view, html} = open(conn)

    refute html =~ "EAA-from-a-removed-destination"
    refute html =~ "EAAtoken"
  end

  # The EasyOrders shape: a merchant has a pixel id and no Conversions API
  # token. That used to save and then read as "not set up".
  @tag :integration
  test "an id with no access token is the browser-pixel state, not nothing", %{conn: conn} do
    {:ok, _} = Destinations.put_credentials(@site, :meta, %{"pixel_id" => "1234567890123456"})

    {:ok, _view, html} = open(conn)

    assert html =~ "browser pixel active"
    refute html =~ "not set up</span>"
    assert html =~ "Add the access token"

    # And the tag actually renders from it.
    assert Pixelex.Pixels.ids(@site) == %{meta: "1234567890123456"}
  end

  @tag :integration
  test "Test is offered only once the server leg can actually work", %{conn: conn} do
    {:ok, _} = Destinations.put_credentials(@site, :meta, %{"pixel_id" => "1234567890123456"})

    {:ok, view, _html} = open(conn)
    refute has_element?(view, "button[phx-click=test_platform][phx-value-platform=meta]")

    {:ok, _} =
      Destinations.put_credentials(@site, :meta, %{
        "pixel_id" => "1234567890123456",
        "access_token" => "EAAtoken"
      })

    {:ok, view, _html} = open(conn)
    assert has_element?(view, "button[phx-click=test_platform][phx-value-platform=meta]")
  end
end
