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

    ## Counting each visitor once

    `mount/3` and `handle_params/3` both run **twice** on a page load: once for
    the dead render (plain HTML over HTTP) and again when the socket connects.

      * Count both, and every human is two visitors.
      * Count only `connected?/1`, and crawlers, no-JS clients and anyone whose
        socket never opens vanish — the same trade as JS beacon versus
        `<noscript>` pixel, moved to the server.

    No socket flag separates the two cases: a `push_navigate` into a LiveView
    also mounts exactly once, connected, with no dead render before it. So the
    test is behavioural, in `Pixelex.Sessions.first_view?/3` — the same session
    asking for the same path twice within five seconds is one page view. Both
    renders are attempted; the second is dropped as `:duplicate_pageview`, and
    the `render` column records which one won.

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
        |> attach_hook(:pixelex, :handle_params, &on_params/3)

      {:cont, socket}
    end

    def on_mount(name, params, session, socket) when is_atom(name),
      do: on_mount([], params, session, socket)

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

      unless rejoin?(socket) or skip?(socket) do
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
      connect = if connected?(socket), do: get_connect_params(socket) || %{}, else: %{}

      %{
        site_id: site_id(socket, opts, uri),
        ip: peer_ip(socket),
        user_agent: get_connect_info(socket, :user_agent) || stashed[:user_agent],
        url: uri,
        # The WebSocket carries no Referer. Without the stash, every LiveView
        # visit after the first render looks like direct traffic.
        referrer: connect["r"] || stashed[:referrer],
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

    # `_mounts` is 0 the first time a client mounts and increments on every
    # rejoin. Without this check a rolling deploy reads as a traffic spike.
    defp rejoin?(socket) do
      connected?(socket) and
        case get_connect_params(socket) do
          %{"_mounts" => n} when is_integer(n) and n > 0 -> true
          _ -> false
        end
    end

    defp skip?(socket) do
      case socket.assigns[:pixelex_opts][:skip] do
        fun when is_function(fun, 1) -> fun.(socket)
        _ -> false
      end
    end

    defp site_id(socket, opts, uri) do
      case opts[:site_id] do
        id when is_binary(id) -> id
        fun when is_function(fun, 1) -> fun.(socket)
        _ -> hostname(uri)
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
    defp peer_ip(socket) do
      case get_connect_info(socket, :peer_data) do
        %{address: address} when is_tuple(address) -> address |> :inet.ntoa() |> to_string()
        _ -> forwarded_ip(socket)
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
