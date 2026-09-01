if Code.ensure_loaded?(Plug) do
  defmodule Pixelex.Plug.Ingest do
    @moduledoc """
    The browser's way in: `POST /px/e` and `GET /px.gif`.

        # router.ex
        forward "/px", Pixelex.Plug.Ingest

    Only needed for what the server cannot see on its own — custom events from
    a click, SPA navigation, screen size, scroll depth. Page views are already
    counted by `Pixelex.Plug` with no JavaScript at all.

    ## It answers the same way to everything

    `204 No Content` for the POST, a 1×1 GIF for the pixel — whether the event
    was recorded, dropped as a bot, refused for consent, rate-limited, or had a
    name the site never allowed. A response that distinguishes those hands a
    scanner the site's event catalogue and its consent posture for free.

    Every outcome is still counted under `[:pixelex, :pipeline, :drop]`, so the
    silence is toward the caller, not toward the operator.

    ## What bounds an unauthenticated endpoint

    Not authentication — most of the clicks worth counting happen before anyone
    signs in. Four things, none of which is auth:

      * the per-site event allowlist (`Pixelex.Sites`) — the server decides what
        names exist
      * the consent gate, including `Sec-GPC`
      * bot filtering
      * `Pixelex.RateLimit`, 120 events per minute per IP by default: far above
        a human, far below a script

    ## `GET /px.gif`

    For `<noscript>`, and for email. A GIF rather than `204` because a `204`
    response to an `<img src>` is not well-trodden ground across browsers,
    which is the same conclusion Matomo reached. 43 bytes.

    ## `GET /px/pixelex.js`

    The tracker itself, from the host's own origin. 1.5KB gzipped.

    ## The payload

    Short keys, because this is on the wire on every event:
    `s` site, `n` name, `u` url, `r` referrer, `p` props, `t` client time in ms.
    """
    @behaviour Plug

    import Plug.Conn

    alias Pixelex.{Config, RateLimit, Sites}
    alias Pixelex.Plug.Context

    # 42 bytes: a 1x1 transparent GIF.
    @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

    # Read at compile time so a release has no dependency on priv/ being
    # readable at runtime, and so the ETag is fixed for the life of the build.
    @tracker (case File.read(Path.join(:code.priv_dir(:pixelex), "static/pixelex.js")) do
                {:ok, contents} -> contents
                {:error, _} -> nil
              end)

    @tracker_etag if @tracker,
                    do: ~s("#{Base.encode16(:crypto.hash(:md5, @tracker), case: :lower)}")

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", path_info: path} = conn, opts) when path in [["e"], []] do
      {payload, conn} = read_json(conn)

      record(conn, payload, :client, opts)
      send_resp(conn, :no_content, "")
    end

    def call(%{method: "GET", path_info: ["px.gif"]} = conn, opts) do
      conn = fetch_query_params(conn)

      record(conn, conn.query_params, :client, opts)

      conn
      |> put_resp_content_type("image/gif")
      |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
      |> send_resp(200, @gif)
    end

    if @tracker do
      def call(%{method: "GET", path_info: ["pixelex.js"]} = conn, _opts), do: tracker(conn)
    end

    def call(conn, _opts), do: send_resp(conn, :not_found, "")

    # Served from the host's own origin, which is the whole point: a
    # first-party path is not on any filter list, and there is no third-party
    # domain for a browser to block or a privacy extension to flag. It also
    # means no Subresource Integrity attribute is needed — the script and the
    # page share an origin — though the hash is published in
    # priv/static/pixelex.js.sri for anyone serving it from a CDN.
    if @tracker do
      defp tracker(conn) do
        cond do
          stale?(conn) ->
            conn
            |> put_resp_content_type("application/javascript")
            |> put_resp_header("etag", @tracker_etag)
            # A day, and it must revalidate after: the tracker changes only on
            # a release, but a stale one that cannot be replaced is a bug that
            # outlives its fix.
            |> put_resp_header("cache-control", "public, max-age=86400, must-revalidate")
            |> send_resp(200, @tracker)

          true ->
            conn
            |> put_resp_header("etag", @tracker_etag)
            |> send_resp(304, "")
        end
      end

      defp stale?(conn), do: get_req_header(conn, "if-none-match") != [@tracker_etag]
    end

    # --- recording ------------------------------------------------------------

    defp record(conn, payload, render, opts) when is_map(payload) do
      site_id = presence(payload["s"]) || opts[:site_id] || conn.host
      name = presence(payload["n"]) || Pixelex.Pipeline.pageview_name()

      with :ok <- rate_limit(conn),
           :ok <- allowed_event(site_id, name) do
        conn
        |> Context.build(
          site_id: site_id,
          render: render,
          url: presence(payload["u"]),
          referrer: presence(payload["r"]),
          client_ts: client_ts(payload["t"])
        )
        |> Pixelex.track(name, props(payload["p"]))
      end
    rescue
      e ->
        # An open endpoint receives deliberately malformed input. Answering 204
        # is the whole contract; raising would answer 500 and say so. But the
        # operator still needs to hear about it, or a bug in this path is
        # indistinguishable from a quiet week.
        require Logger
        Logger.warning("Pixelex ingest dropped an event: #{inspect(e)}")
        :ok
    end

    defp rate_limit(conn) do
      {limit, window} = Config.rate_limit()
      ip = Context.client_ip(conn) || "unknown"

      case RateLimit.hit("px:#{ip}", window, limit) do
        {:allow, _} ->
          :ok

        {:deny, _} ->
          :telemetry.execute([:pixelex, :pipeline, :drop], %{count: 1}, %{reason: :rate_limited})
          :dropped
      end
    end

    defp allowed_event(site_id, name) do
      if Sites.allowed_event?(Sites.get(site_id), name) do
        :ok
      else
        :telemetry.execute([:pixelex, :pipeline, :drop], %{count: 1}, %{
          reason: :event_not_allowed,
          site_id: site_id
        })

        :dropped
      end
    end

    # --- payload --------------------------------------------------------------

    defp read_json(conn) do
      # Parsers may already have run in the host's pipeline. When they have,
      # body_params is the payload; when they have not, read it here — this
      # endpoint must work forwarded from any pipeline, including one with no
      # parsers, because it is not part of the host's API surface.
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> read_body_json(conn)
        params when is_map(params) and map_size(params) > 0 -> {params, conn}
        _ -> read_body_json(conn)
      end
    end

    defp read_body_json(conn) do
      case read_body(conn, length: 64_000) do
        {:ok, body, conn} -> {decode(body), conn}
        {:more, _partial, conn} -> {%{}, conn}
        {:error, _reason} -> {%{}, conn}
      end
    end

    defp decode(body) when is_binary(body) and body != "" do
      case Jason.decode(body) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end

    defp decode(_), do: %{}

    defp props(p) when is_map(p), do: p
    defp props(_), do: %{}

    # The browser's clock, kept as sent. Correcting it is the query layer's
    # job; storing the raw claim is what makes the correction possible.
    defp client_ts(ms) when is_integer(ms) and ms > 0 do
      case DateTime.from_unix(ms, :millisecond) do
        {:ok, dt} -> dt
        _ -> nil
      end
    end

    defp client_ts(ms) when is_binary(ms) do
      case Integer.parse(ms) do
        {int, ""} -> client_ts(int)
        _ -> nil
      end
    end

    defp client_ts(_), do: nil

    defp presence(v) when is_binary(v) and v != "", do: v
    defp presence(_), do: nil
  end
end
