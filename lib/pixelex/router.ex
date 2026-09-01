if Code.ensure_loaded?(Phoenix.Router) do
  defmodule Pixelex.Router do
    @moduledoc """
    Router macros for the ingest endpoint and the dashboard.

        defmodule MyAppWeb.Router do
          use MyAppWeb, :router
          import Pixelex.Router

          # the browser's way in: POST /px/e, GET /px/px.gif, GET /px/pixelex.js
          pixelex_ingest "/px"

          scope "/admin" do
            pipe_through [:browser, :require_admin]
            pixelex_dashboard "/analytics"
          end
        end

    ## The ingest endpoint takes no pipeline

    `pixelex_ingest/2` deliberately forwards outside the `:browser` pipeline.
    Session fetching, flash and CSRF protection are all wrong here: the
    endpoint is called by a beacon on pages the visitor is not signed in to,
    and a CSRF token would have to be embedded in the tracker for every page,
    which is not protection, it is ceremony. What actually bounds it is the
    per-site event allowlist, the consent gate, bot filtering and the rate
    limiter — see `Pixelex.Plug.Ingest`.

    ## The dashboard takes yours

    `pixelex_dashboard/2` mounts a LiveView and inherits whatever pipeline it
    is scoped inside. **It has no authentication of its own.** Put it behind
    yours. A site's full traffic, sources and funnels are not public data, and
    a library that shipped its own auth would be a second login for you to
    maintain and a first one for an attacker to find.
    """

    @doc """
    Mount the ingest endpoint at `path`.

    Configure the tracker to match with
    `config :pixelex, ingest_path: "/px"` — the path is configurable precisely
    because a fixed, well-known one is what ends up on a filter list.
    """
    defmacro pixelex_ingest(path \\ "/px", opts \\ []) do
      quote bind_quoted: [path: path, opts: opts] do
        scope path, alias: false, as: false do
          forward("/", Pixelex.Plug.Ingest, opts)
        end
      end
    end

    @doc """
    Mount the dashboard at `path`.

    ## Options

      * `:site_id` — pin the dashboard to one site. Omitted, it reads `?site=`
        and defaults to the request host.
      * `:on_mount` — extra `on_mount` hooks, for your own authorisation.
      * `:live_session_name` — defaults to `:pixelex_dashboard`.
    """
    defmacro pixelex_dashboard(path \\ "/analytics", opts \\ []) do
      quote bind_quoted: [path: path, opts: opts] do
        scope path, alias: false, as: false do
          # Built rather than written literally: live_session rejects
          # `root_layout: nil` outright rather than treating it as absent, so
          # passing the option through unconditionally breaks every router that
          # does not set one — which is most of them.
          live_session_opts =
            [
              on_mount: List.wrap(opts[:on_mount]),
              session: %{"pixelex_site_id" => opts[:site_id]}
            ]
            |> then(fn base ->
              case opts[:root_layout] do
                nil -> base
                layout -> Keyword.put(base, :root_layout, layout)
              end
            end)

          live_session opts[:live_session_name] || :pixelex_dashboard, live_session_opts do
            # No live action, and an explicit :as. The enclosing scope sets
            # `as: false` to keep pixelex out of the host's route helpers, and
            # a live action then has nothing to infer a name from.
            live("/", Pixelex.Dashboard.Live, nil, as: :pixelex_dashboard)
          end
        end
      end
    end
  end
end
