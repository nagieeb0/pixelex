if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Pixelex.LiveView do
    @moduledoc """
    Page views from a LiveView, including the ones a page reload never happens
    for.

        live_session :default, on_mount: [Pixelex.LiveView] do
          live "/", HomeLive
          live "/pricing", PricingLive
        end

    ## What makes LiveView different

    Three navigations that look the same to a user and nothing like each other
    to the server:

    | in the template | server | client |
    |---|---|---|
    | `<.link href=>` | full HTTP request, new mount | normal page load |
    | `<.link navigate=>` | old LiveView dismounted, new one mounted, **no HTTP request** | `phx:navigate` |
    | `<.link patch=>` | **same** LiveView, `handle_params/3` only | `phx:navigate` |

    Two of the three never reach a `Plug`, which is why a request-counting plug
    alone reports a LiveView app as a one-page site. This hook attaches to
    `handle_params`, which is the one callback all three run through.

    ## Counting each visitor once — and why this hook needs `Pixelex.Plug`

    `mount/3` and `handle_params/3` both run **twice** on a page load: once for
    the dead render (plain HTML over HTTP) and again when the socket connects.
    Count both and every human is two visitors.

    The division of labour:

      * **`Pixelex.Plug` records the dead render.** It runs inside the HTTP
        request, so it has the real client IP, user agent and `Referer`. This
        is also what counts crawlers and clients whose socket never opens.
      * **This hook records connected renders**, and the initial one is dropped
        by `Pixelex.Sessions.first_view?/3` as a duplicate of what the plug
        just wrote — same visitor, same path, within seconds.
      * `live_patch` and `live_navigate` change the path, so they pass the
        duplicate check and are counted. Neither ever reaches a plug.

    **The hook deliberately ignores dead renders**, and this is not an
    optimisation. `get_connect_info/2` returns nothing during a dead render, so
    there is no peer address to hash — the visitor would come out as a
    *different* person from the one the plug recorded a moment earlier, and the
    duplicate check would never fire. Every page load would count twice.

    So `plug Pixelex.Plug` in your endpoint is required, not optional, for a
    LiveView app. Without it, initial page views are not counted at all.

    ## Reconnects

    A dropped WiFi connection, a closed laptop lid, or a rolling deploy re-runs
    `mount/3` for every connected client. Left alone, a deploy inflates page
    views by the size of the connected user base — a number that looks like
    growth. LiveView sends `_mounts` in the connect params: `0` on a client's
    first mount and higher on every rejoin after it, so a rejoin is skipped.

    ## The referrer is only there once

    `Referer` arrives on the initial HTTP request and never again — the
    WebSocket has no such header. `Pixelex.Plug` stashes it in the session, and
    this hook reads it back, so attribution survives the socket upgrade.

    ## Options

        on_mount: {Pixelex.LiveView, site_id: "shop", skip: &MyApp.admin?/1}
    """
    import Phoenix.LiveView
    import Phoenix.Component, only: [assign: 3]

    require Logger

    @doc false
    def on_mount(opts \\ [], params, session, socket)

    def on_mount(opts, _params, session, socket) when is_list(opts) do
      socket =
        socket
        |> assign(:pixelex_opts, opts)
        |> assign(:pixelex_session, pixelex_session(session))
        # Everything the socket knows about the request, captured HERE and
        # nowhere else. `get_connect_info/2` and `get_connect_params/1` are
        # readable only during mount/3 and raise afterwards — and this runs
        # inside a rescue, so the failure was the worst possible kind: every
        # live_patch silently uncounted, no error surfaced, and a LiveView app
        # reporting itself as a one-page site.
        |> assign(:pixelex_mount, mount_context(socket))
        |> attach_params_hook()

      {:cont, socket}
    end

    def on_mount(name, params, session, socket) when is_atom(name),
      do: on_mount([], params, session, socket)

    # attach_hook/4 on :handle_params RAISES for a LiveView that was not mounted
    # at the router — a nested one rendered with live_render/3, for instance.
    # A host that puts this hook on a live_session containing nested views
    # would get an exception on mount and a dead page, from analytics.
    #
    # A nested LiveView has no navigation of its own to observe anyway; the
    # parent owns the URL. So skip quietly.
    defp attach_params_hook(socket) do
      if socket.router do
        attach_hook(socket, :pixelex, :handle_params, &on_params/3)
      else
        socket
      end
    end

    @doc """
    Record an event from inside a LiveView.

        Pixelex.LiveView.track(socket, "booking_completed", %{value: 1499.0})
    """
    @spec track(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
    def track(socket, name, props) when is_binary(name) and is_map(props) do
      socket
      |> context(socket.assigns[:pixelex_uri])
      |> Pixelex.track(name, props)

      socket
    rescue
      _ -> socket
    end

    # --- the handle_params hook ------------------------------------------------

    defp on_params(_params, uri, socket) do
      # Stash the URI so track/3 can be called later from a handle_event with
      # the right page attached; LiveView exposes it here and nowhere else.
      socket = assign(socket, :pixelex_uri, uri)

      if record?(socket) do
        socket
        |> context(uri)
        |> Pixelex.page()
      end

      {:cont, socket}
    rescue
      e ->
        # A hook that raises takes the page down with it. Nothing about
        # counting a visit is worth that.
        Logger.warning("Pixelex LiveView hook: #{inspect(e)}")
        {:cont, socket}
    end

    defp context(socket, uri) do
      opts = socket.assigns[:pixelex_opts] || []
      stashed = socket.assigns[:pixelex_session] || %{}
      mount = socket.assigns[:pixelex_mount] || %{}

      %{
        site_id: site_id(socket, opts, uri),
        ip: mount[:ip],
        user_agent: mount[:user_agent] || stashed[:user_agent],
        url: uri,
        # The WebSocket carries no Referer. Without the stash, every LiveView
        # visit after the first render looks like direct traffic.
        referrer: mount[:referrer] || stashed[:referrer],
        hostname: hostname(uri),
        country: stashed[:country],
        user_id: user_id(socket, opts),
        render: if(connected?(socket), do: :connected, else: :dead),
        consent: %{
          country: stashed[:country],
          decision: stashed[:consent],
          gpc: stashed[:gpc],
          dnt: stashed[:dnt]
        }
      }
    end

    defp record?(socket) do
      mount = socket.assigns[:pixelex_mount] || %{}
      connected?(socket) and not mount[:rejoin?] and not skip?(socket)
    end

    # Called once, from on_mount/4, while the connect data is still readable.
    defp mount_context(socket) do
      params = connect_params(socket)

      %{
        ip: peer_ip(socket),
        user_agent: safe_connect_info(socket, :user_agent),
        referrer: params["r"],
        rejoin?: rejoin?(params)
      }
    end

    defp safe_connect_info(socket, key) do
      if connected?(socket), do: get_connect_info(socket, key)
    rescue
      _ -> nil
    end

    @doc """
    Is this mount a client rejoining, rather than arriving?

    LiveView sends `_mounts` in the connect params: `0` the first time a client
    mounts a page and higher on every rejoin after it — a dropped connection, a
    closed laptop lid, a rolling deploy. Every one of those re-runs `mount/3`
    for every connected client, so without this check a deploy inflates page
    views by the size of the connected user base, which looks exactly like
    growth.

    Public because `Phoenix.LiveViewTest` overrides `_mounts` with its own
    value and ignores `put_connect_params/2` for that key, so this branch
    cannot be reached through a simulated mount. Untestable code in the path of
    every page view is not acceptable; a documented function is.
    """
    @spec rejoin?(map()) :: boolean()
    def rejoin?(%{"_mounts" => n}) when is_integer(n) and n > 0, do: true
    def rejoin?(_connect_params), do: false

    defp connect_params(socket) do
      if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}
    rescue
      _ -> %{}
    end

    defp skip?(socket) do
      case socket.assigns[:pixelex_opts][:skip] do
        fun when is_function(fun, 1) -> fun.(socket)
        _ -> false
      end
    end

    # Shared with Pixelex.Plug on purpose. Resolving the site differently in the
    # two places makes the dead render and the connected render hash to
    # different visitors, so the duplicate check never fires and every page
    # view counts twice. See Pixelex.Config.site_id/2.
    defp site_id(socket, opts, uri) do
      case opts[:site_id] do
        fun when is_function(fun, 1) -> fun.(socket)
        override -> Pixelex.Config.site_id(hostname(uri), override)
      end
    end

    defp user_id(socket, opts) do
      case opts[:user_id] do
        fun when is_function(fun, 1) ->
          fun.(socket)

        _ ->
          case socket.assigns[:current_user] do
            %{id: id} when is_binary(id) -> id
            %{id: id} when is_integer(id) -> Integer.to_string(id)
            _ -> socket.assigns[:current_user_id]
          end
      end
    end

    # Requires the endpoint to declare what the socket may see:
    #
    #     socket "/live", Phoenix.LiveView.Socket,
    #       websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]
    #
    # Without :peer_data every visitor hashes to nil and a site sees one
    # visitor forever, so this is worth checking on install.
    #
    # The configured proxy header comes FIRST, and that ordering is the whole
    # point. Behind Fly, Cloudflare, Heroku or nginx, `peer_data` is the
    # proxy's address while `Pixelex.Plug` — which reads the header — has the
    # visitor's. The two then hash to different visitors, the duplicate check
    # never fires, and every LiveView page view is counted twice. In
    # production, on every deployment that has a load balancer in front of it.
    defp peer_ip(socket) do
      if connected?(socket), do: forwarded_ip(socket) || peer_data_ip(socket)
    rescue
      _ -> nil
    end

    defp peer_data_ip(socket) do
      case get_connect_info(socket, :peer_data) do
        %{address: address} when is_tuple(address) -> address |> :inet.ntoa() |> to_string()
        _ -> nil
      end
    end

    defp forwarded_ip(socket) do
      header = Application.get_env(:pixelex, :client_ip_header)

      with true <- is_binary(header),
           headers when is_list(headers) <- get_connect_info(socket, :x_headers),
           {_name, value} <- List.keyfind(headers, header, 0) do
        value |> String.split(",") |> List.first() |> String.trim()
      else
        _ -> nil
      end
    end

    defp pixelex_session(session) when is_map(session) do
      %{
        referrer: session["pixelex_referrer"],
        user_agent: session["pixelex_user_agent"],
        country: session["pixelex_country"],
        consent: session["pixelex_consent"],
        gpc: session["pixelex_gpc"],
        dnt: session["pixelex_dnt"]
      }
    end

    defp pixelex_session(_), do: %{}

    defp hostname(uri) when is_binary(uri) do
      case URI.parse(uri) do
        %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
        _ -> nil
      end
    end

    defp hostname(_), do: nil
  end
end
