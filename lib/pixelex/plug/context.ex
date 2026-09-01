if Code.ensure_loaded?(Plug) do
  defmodule Pixelex.Plug.Context do
    @moduledoc """
    A `Plug.Conn` turned into a pipeline context.

    This is where pixelex's server-first stance pays off: the IP, user agent,
    referrer, language and privacy headers are all already here, on every
    request, before any JavaScript has run. Nothing needs to be asked of the
    browser to produce a complete analytics record — the tracker adds screen
    size and engagement, and nothing else that matters.

    ## Client IP behind a proxy

    `conn.remote_ip` is the load balancer's address on Fly, Heroku, Cloudflare
    and behind nginx — so every visitor hashes to the same id and a site sees
    one visitor forever. Configure the header the proxy actually sets:

        config :pixelex, client_ip_header: "fly-client-ip"

    `x-forwarded-for` is supported and its **left-most** entry is taken. That
    entry is client-controlled, so it is only trusted when explicitly
    configured; the default reads `conn.remote_ip` and is wrong-but-safe rather
    than forgeable.

    ## Country

    Taken from a CDN header when one is present — `cf-ipcountry`,
    `fly-client-country`, `x-vercel-ip-country` are checked by default, and
    `:country_header` overrides. No GeoIP database is bundled: the hosts these
    apps run on already do the lookup, and shipping a 70MB database plus its
    licence to duplicate that would be a poor trade.
    """
    import Plug.Conn

    alias Pixelex.Consent

    @country_headers ~w(cf-ipcountry fly-client-country x-vercel-ip-country x-country-code)
    @city_headers ~w(cf-ipcity x-vercel-ip-city)
    @region_headers ~w(cf-region x-vercel-ip-country-region)

    @doc """
    Build a context from a connection.

    ## Options

      * `:site_id` — required unless resolvable from the host
      * `:render` — defaults to `:dead`
      * `:url`, `:referrer` — override what the connection says, for the ingest
        endpoint where the real page is in the payload rather than the request
    """
    @spec build(Plug.Conn.t(), keyword()) :: map()
    def build(conn, opts \\ []) do
      %{
        site_id: Pixelex.Config.site_id(conn.host, opts[:site_id]),
        ip: client_ip(conn),
        user_agent: header(conn, "user-agent"),
        url: opts[:url] || Plug.Conn.request_url(conn),
        referrer: opts[:referrer] || header(conn, "referer"),
        hostname: conn.host,
        country: opts[:country] || first_header(conn, @country_headers),
        region: first_header(conn, @region_headers),
        city: first_header(conn, @city_headers),
        user_id: opts[:user_id] || current_user_id(conn),
        client_ts: opts[:client_ts],
        render: opts[:render] || :dead,
        consent: consent(conn, opts)
      }
    end

    @doc "The visitor's real IP, honouring a configured proxy header."
    @spec client_ip(Plug.Conn.t()) :: String.t() | nil
    def client_ip(conn) do
      case Application.get_env(:pixelex, :client_ip_header) do
        header when is_binary(header) ->
          case header(conn, header) do
            nil -> remote_ip(conn)
            value -> leftmost(value) || remote_ip(conn)
          end

        _ ->
          remote_ip(conn)
      end
    end

    @doc "Consent signals: the privacy headers, plus whatever the host's banner recorded."
    @spec consent(Plug.Conn.t(), keyword()) :: Consent.signals()
    def consent(conn, opts \\ []) do
      %{
        country: opts[:country] || first_header(conn, @country_headers),
        decision: opts[:decision] || Pixelex.Plug.Cookies.consent_decision(conn),
        gpc: header(conn, "sec-gpc"),
        dnt: header(conn, "dnt")
      }
    end

    # --- internals ----------------------------------------------------------

    defp current_user_id(conn) do
      case conn.assigns[:current_user] do
        %{id: id} when is_binary(id) -> id
        %{id: id} when is_integer(id) -> Integer.to_string(id)
        _ -> conn.assigns[:current_user_id]
      end
    end

    defp remote_ip(%{remote_ip: ip}) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
    defp remote_ip(_), do: nil

    # X-Forwarded-For is "client, proxy1, proxy2"; the client is on the left.
    defp leftmost(value) do
      value
      |> String.split(",")
      |> List.first()
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        ip -> ip
      end
    end

    defp header(conn, name) do
      case get_req_header(conn, name) do
        [value | _] when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end

    defp first_header(conn, names), do: Enum.find_value(names, &header(conn, &1))
  end
end
