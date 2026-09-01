if Code.ensure_loaded?(Plug) do
  defmodule Pixelex.Plug do
    @moduledoc """
    Count page views from the server. No JavaScript, nothing to block.

        # lib/my_app_web/endpoint.ex, after Plug.Static
        plug Pixelex.Plug

    ## Why this is the primary transport and the tracker is the optional one

    Every hosted analytics product measures from the browser because it has no
    other choice — it is not running inside your application. A library is, so
    it can count the request itself. Nothing is on a filter list, nothing
    depends on JavaScript executing, and the record is already complete before
    the response is sent.

    Plausible's own case study found a site losing **58% of visitors** to
    ad-blockers with Google Analytics. That number is an upper bound on
    third-party scripts, and it is the number this plug does not have.

    ## What it skips, and why

    Anything that is not a person looking at a page: non-GET requests, non-HTML
    responses, non-2xx responses, and the ingest endpoint itself. Counting a
    stylesheet as a page view is the failure mode of naive request logging, and
    it is why "page views" from a request log never match anything.

    ## Options

      * `:site_id` — a string, or a `fun(conn)`. Defaults to the request host.
      * `:skip` — a `fun(conn)` returning true to ignore a request.
      * `:paths` — only count requests whose path starts with one of these.
    """
    @behaviour Plug

    alias Pixelex.Plug.Context

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      if capture?(conn, opts) do
        Plug.Conn.register_before_send(conn, &record(&1, opts))
      else
        conn
      end
    end

    # Registered before_send rather than run inline, because status and
    # content-type are not known until the response is built — and a redirect,
    # a 404 and a JSON API reply are all not page views.
    defp record(conn, opts) do
      if html_success?(conn) do
        conn
        |> Context.build(
          site_id: site_id(conn, opts),
          render: :dead
        )
        |> Pixelex.page()
      end

      conn
    rescue
      e ->
        # before_send callbacks run while the response is being sent, so an
        # exception here would replace a working page with a 500. It still gets
        # logged: a rescue that says nothing is how "we have been recording
        # zero page views for a month" happens.
        require Logger
        Logger.warning("Pixelex.Plug failed to record a page view: #{inspect(e)}")
        conn
    end

    defp capture?(conn, opts) do
      conn.method == "GET" and
        not ingest_path?(conn) and
        path_allowed?(conn, opts[:paths]) and
        not skipped?(conn, opts[:skip])
    end

    defp html_success?(conn) do
      conn.status in 200..299 and
        conn
        |> Plug.Conn.get_resp_header("content-type")
        |> List.first()
        |> is_html?()
    end

    defp is_html?(nil), do: false
    defp is_html?(content_type), do: String.contains?(content_type, "text/html")

    defp ingest_path?(conn) do
      String.starts_with?(conn.request_path, Pixelex.Config.ingest_path())
    end

    defp path_allowed?(_conn, nil), do: true

    defp path_allowed?(conn, paths) when is_list(paths),
      do: Enum.any?(paths, &String.starts_with?(conn.request_path, &1))

    defp skipped?(_conn, nil), do: false
    defp skipped?(conn, fun) when is_function(fun, 1), do: fun.(conn)
    defp skipped?(_conn, _), do: false

    defp site_id(conn, opts) do
      case opts[:site_id] do
        id when is_binary(id) -> id
        fun when is_function(fun, 1) -> fun.(conn)
        _ -> nil
      end
    end
  end
end
