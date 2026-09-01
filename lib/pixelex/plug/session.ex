if Code.ensure_loaded?(Plug) do
  defmodule Pixelex.Plug.Session do
    @moduledoc """
    Carry what only the HTTP request knows into the LiveView socket.

        # router.ex, in the :browser pipeline, after fetch_session
        plug Pixelex.Plug.Session

    ## Why this is necessary

    A LiveView's WebSocket has no `Referer` header. It is sent once, on the
    initial HTTP request, and never again. Without somewhere to put it, every
    LiveView visit after the first render is attributed to direct traffic and
    the whole attribution story collapses for exactly the apps this library is
    built for.

    The same is true of the CDN's country header and the consent decision. The
    session is the one place both the request and the socket can see.

    Written once per session rather than on every request: the values describe
    how this visitor arrived, and overwriting the referrer on their fourth page
    would replace "came from a Google ad" with "came from our own pricing page".
    """
    @behaviour Plug

    import Plug.Conn

    @country_headers ~w(cf-ipcountry fly-client-country x-vercel-ip-country x-country-code)

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      if get_session(conn, "pixelex_landed") do
        refresh_volatile(conn)
      else
        conn
        |> put_session("pixelex_landed", true)
        |> put_session("pixelex_referrer", header(conn, "referer"))
        |> put_session("pixelex_user_agent", header(conn, "user-agent"))
        |> refresh_volatile()
      end
    rescue
      # No session configured, or it is not fetched yet. Not worth a 500.
      _ -> conn
    end

    # Country and the privacy signals can change mid-session — a VPN, a
    # consent banner being answered — so unlike the referrer these are
    # refreshed on every request.
    defp refresh_volatile(conn) do
      conn
      |> put_session("pixelex_country", Enum.find_value(@country_headers, &header(conn, &1)))
      |> put_session("pixelex_gpc", header(conn, "sec-gpc"))
      |> put_session("pixelex_dnt", header(conn, "dnt"))
      |> maybe_put_consent()
    end

    defp maybe_put_consent(conn) do
      case Pixelex.Plug.Cookies.consent_decision(conn) do
        nil -> conn
        decision -> put_session(conn, "pixelex_consent", decision)
      end
    end

    defp header(conn, name) do
      case get_req_header(conn, name) do
        [value | _] when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end
  end
end
