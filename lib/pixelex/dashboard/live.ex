if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Pixelex.Dashboard.Live do
    @moduledoc """
    The dashboard: traffic, sources, pages, devices, events and a funnel
    builder, in one LiveView.

        pixelex_dashboard "/analytics"

    ## No dependencies of its own

    No Tailwind, no chart library, no CDN. The styles are one scoped block and
    the chart is inline SVG. A host that does not use Tailwind should not have
    to adopt it to see their traffic, and a library that pulls a chart bundle
    from a CDN has quietly reintroduced the third-party request pixelex exists
    to avoid.

    ## Every query is bounded

    The range picker offers fixed windows, `Pixelex.Query` requires `from` and
    `to`, and every table is limited. There is no "all time".

    ## It has no authentication

    Scope it behind yours. See `Pixelex.Router`.
    """
    use Phoenix.LiveView

    alias Pixelex.Query
    alias Pixelex.Query.{Funnel, Interactions, Traffic}

    @ranges [
      {"24h", :today, "Last 24 hours"},
      {"7d", :last_7_days, "Last 7 days"},
      {"30d", :last_30_days, "Last 30 days"},
      {"90d", :last_90_days, "Last 90 days"}
    ]

    @impl true
    def mount(params, session, socket) do
      site_id = session["pixelex_site_id"] || params["site"] || host(socket)

      {:ok,
       socket
       |> assign(:site_id, site_id)
       |> assign(:range_key, "7d")
       |> assign(:funnel_steps, [])
       |> assign(:funnel, nil)
       |> assign(:page_title, "Analytics")
       |> load()}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      case params["range"] do
        key when is_binary(key) -> {:noreply, socket |> assign(:range_key, key) |> load()}
        _ -> {:noreply, socket}
      end
    end

    @impl true
    def handle_event("range", %{"key" => key}, socket) do
      {:noreply, socket |> assign(:range_key, key) |> load()}
    end

    def handle_event("funnel", %{"steps" => raw}, socket) do
      steps =
        raw
        |> String.split(~r/[\n,]/, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(10)

      funnel =
        if steps == [] do
          nil
        else
          try do
            Funnel.run(socket.assigns.site_id, range(socket.assigns.range_key), steps)
          rescue
            e -> %{error: Exception.message(e)}
          end
        end

      {:noreply, socket |> assign(:funnel_steps, steps) |> assign(:funnel, funnel)}
    end

    # --- data -----------------------------------------------------------------

    defp load(socket) do
      site = socket.assigns.site_id
      range = range(socket.assigns.range_key)

      assign(socket,
        summary: Traffic.summary(site, range),
        series: Traffic.timeseries(site, range),
        pages: Traffic.top_pages(site, range, limit: 10),
        sources: Traffic.sources(site, range, limit: 10),
        mediums: Traffic.mediums(site, range, limit: 10),
        campaigns: Traffic.campaigns(site, range, limit: 10),
        countries: Traffic.countries(site, range, limit: 10),
        devices: Traffic.devices(site, range, limit: 10),
        browsers: Traffic.browsers(site, range, limit: 10),
        events: Traffic.events(site, range, limit: 10),
        inventory: Interactions.inventory(site, range, limit: 20),
        clicks: Interactions.clicks(site, range, limit: 20),
        engagement: Interactions.engagement(site, range),
        timeline: Interactions.timeline(site, range, limit: 30)
      )
    rescue
      e ->
        assign(socket,
          load_error: Exception.message(e),
          summary: nil,
          series: [],
          pages: [],
          sources: [],
          mediums: [],
          campaigns: [],
          countries: [],
          devices: [],
          browsers: [],
          events: [],
          inventory: [],
          clicks: [],
          engagement: nil,
          timeline: []
        )
    end

    defp range(key) do
      {_key, preset, _label} =
        Enum.find(@ranges, List.first(@ranges), fn {k, _p, _l} -> k == key end)

      Query.range(preset)
    end

    defp host(socket) do
      case get_connect_info(socket, :uri) do
        %URI{host: host} when is_binary(host) -> host
        _ -> "localhost"
      end
    end

    # --- render ---------------------------------------------------------------

    @impl true
    def render(assigns) do
      assigns = assign(assigns, :ranges, @ranges)

      ~H"""
      <div class="px-root">
        <style>
          <%= styles() %>
        </style>

        <header class="px-header">
          <div>
            <h1>Analytics</h1>
            <p class="px-site">{@site_id}</p>
          </div>
          <nav class="px-ranges">
            <button
              :for={{key, _preset, label} <- @ranges}
              phx-click="range"
              phx-value-key={key}
              class={["px-range", key == @range_key && "px-range-on"]}
              title={label}
            >
              {key}
            </button>
          </nav>
        </header>

        <p :if={assigns[:load_error]} class="px-error">
          Could not read the event log: {@load_error}
        </p>

        <section :if={@summary} class="px-tiles">
          <.tile label="Page views" value={number(@summary.pageviews)} />
          <.tile label="Sessions" value={number(@summary.sessions)} />
          <.tile
            label="Visitors"
            value={number(@summary.visitors_daily_sum)}
            note="daily sum — the hash rotates at midnight"
          />
          <.tile label="Bounce rate" value={percent(@summary.bounce_rate)} />
          <.tile label="Views / session" value={Float.to_string(@summary.views_per_session)} />
          <.tile label="Events" value={number(@summary.events)} />
        </section>

        <section :if={@series != []} class="px-card">
          <h2>Traffic</h2>
          <.chart series={@series} />
        </section>

        <section :if={@engagement} class="px-tiles">
          <.tile label="Average scroll depth" value={percent_number(@engagement.average_depth)} />
          <.tile label="Deepest scroll" value={percent_number(@engagement.maximum_depth)} />
          <.tile label="Engaged time" value={duration(@engagement.engaged_ms)} />
          <.tile label="Engaged sessions" value={number(@engagement.sessions)} />
        </section>

        <div class="px-grid">
          <.inventory_table rows={@inventory} />
          <.click_table rows={@clicks} />
        </div>

        <div class="px-grid">
          <.table title="Pages" rows={@pages} />
          <.table title="Sources" rows={@sources} />
          <.table title="Channels" rows={@mediums} />
          <.table title="Countries" rows={@countries} />
          <.table title="Devices" rows={@devices} />
          <.table title="Browsers" rows={@browsers} />
          <.table title="Events" rows={@events} />
          <.campaign_table rows={@campaigns} />
        </div>

        <section class="px-card">
          <h2>Funnel</h2>
          <p class="px-hint">
            One event name per line, in order. Keyed on the visitor hash, so a funnel
            here cannot span midnight UTC — use <code>subject: :user</code> in code for
            anything longer.
          </p>

          <form phx-submit="funnel">
            <textarea
              name="steps"
              rows="4"
              placeholder={"px.pageview\nbook_click\nbooking_completed"}
            >{Enum.join(@funnel_steps, "\n")}</textarea>
            <button type="submit" class="px-button">Run</button>
          </form>

          <p :if={@funnel && Map.has_key?(@funnel, :error)} class="px-error">
            {@funnel.error}
          </p>

          <.funnel_result :if={@funnel && Map.has_key?(@funnel, :steps)} funnel={@funnel} />
        </section>

        <.timeline rows={@timeline} />
      </div>
      """
    end

    attr(:rows, :list, required: true)

    defp inventory_table(assigns) do
      ~H"""
      <section class="px-card">
        <h2>Page inventory</h2>
        <p :if={@rows == []} class="px-empty">No browser inventory yet.</p>
        <table :if={@rows != []} class="px-table">
          <thead><tr><th>Page</th><th class="px-num">Buttons</th><th class="px-num">Links</th></tr></thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>{row.path || "/"}</td><td class="px-num">{row.buttons}</td><td class="px-num">{row.links}</td>
            </tr>
          </tbody>
        </table>
      </section>
      """
    end

    attr(:rows, :list, required: true)

    defp click_table(assigns) do
      ~H"""
      <section class="px-card">
        <h2>Interactions</h2>
        <p :if={@rows == []} class="px-empty">No interactions yet.</p>
        <table :if={@rows != []} class="px-table">
          <thead><tr><th>Action</th><th class="px-num">Clicks</th><th class="px-num">People</th></tr></thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>{row.label || row.action}</td><td class="px-num">{row.events}</td><td class="px-num">{row.visitors}</td>
            </tr>
          </tbody>
        </table>
      </section>
      """
    end

    attr(:rows, :list, required: true)

    defp timeline(assigns) do
      ~H"""
      <section class="px-card">
        <h2>Latest events</h2>
        <p :if={@rows == []} class="px-empty">Nothing yet.</p>
        <table :if={@rows != []} class="px-table">
          <thead><tr><th>When</th><th>Event</th><th>Page</th></tr></thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>{Calendar.strftime(row.at, "%Y-%m-%d %H:%M:%S")}</td>
              <td>{row.name}</td><td>{row.path || "—"}</td>
            </tr>
          </tbody>
        </table>
      </section>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :string, required: true)
    attr(:note, :string, default: nil)

    defp tile(assigns) do
      ~H"""
      <div class="px-tile">
        <span class="px-tile-label">{@label}</span>
        <strong class="px-tile-value">{@value}</strong>
        <span :if={@note} class="px-tile-note">{@note}</span>
      </div>
      """
    end

    attr(:title, :string, required: true)
    attr(:rows, :list, required: true)

    defp table(assigns) do
      assigns = assign(assigns, :max, max_of(assigns.rows))

      ~H"""
      <section class="px-card">
        <h2>{@title}</h2>
        <p :if={@rows == []} class="px-empty">Nothing yet.</p>
        <ol :if={@rows != []} class="px-bars">
          <li :for={row <- @rows}>
            <span class="px-bar" style={"width: #{bar(row.events, @max)}%"}></span>
            <span class="px-bar-label" title={to_string(row.value)}>{row.value}</span>
            <span class="px-bar-value">{number(row.events)}</span>
          </li>
        </ol>
      </section>
      """
    end

    attr(:rows, :list, required: true)

    defp campaign_table(assigns) do
      ~H"""
      <section class="px-card">
        <h2>Campaigns</h2>
        <p :if={@rows == []} class="px-empty">No campaign parameters seen.</p>
        <table :if={@rows != []} class="px-table">
          <thead>
            <tr>
              <th>Campaign</th>
              <th>Network</th>
              <th class="px-num">Sessions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>{row.campaign}</td>
              <td>{row.network}</td>
              <td class="px-num">{number(row.sessions)}</td>
            </tr>
          </tbody>
        </table>
      </section>
      """
    end

    attr(:funnel, :map, required: true)

    defp funnel_result(assigns) do
      assigns = assign(assigns, :first, List.first(assigns.funnel.steps).count)

      ~H"""
      <ol class="px-funnel">
        <li :for={step <- @funnel.steps}>
          <span class="px-bar" style={"width: #{bar(step.count, @first)}%"}></span>
          <span class="px-bar-label">{step.name}</span>
          <span class="px-bar-value">
            {number(step.count)}
            <em>{percent(step.rate)}</em>
          </span>
        </li>
      </ol>
      <p class="px-hint">
        Overall conversion {percent(@funnel.conversion_rate)}.
      </p>
      """
    end

    # An inline SVG sparkline. No chart library, no CDN request, no JavaScript.
    attr(:series, :list, required: true)

    defp chart(assigns) do
      values = Enum.map(assigns.series, & &1.pageviews)
      peak = Enum.max([1 | values])
      count = max(length(values) - 1, 1)

      points =
        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, i} ->
          x = Float.round(i / count * 100, 2)
          y = Float.round(40 - value / peak * 36, 2)
          "#{x},#{y}"
        end)

      assigns =
        assign(assigns,
          points: points,
          area: "0,40 " <> points <> " 100,40",
          peak: peak,
          first: List.first(assigns.series),
          last: List.last(assigns.series)
        )

      ~H"""
      <svg class="px-chart" viewBox="0 0 100 40" preserveAspectRatio="none" role="img"
           aria-label={"Page views, peak #{@peak}"}>
        <polygon points={@area} class="px-chart-area" />
        <polyline points={@points} class="px-chart-line" vector-effect="non-scaling-stroke" />
      </svg>
      <div class="px-chart-axis">
        <span>{@first && @first.at}</span>
        <span>peak {number(@peak)}</span>
        <span>{@last && @last.at}</span>
      </div>
      """
    end

    # --- helpers --------------------------------------------------------------

    defp max_of([]), do: 1
    defp max_of(rows), do: rows |> Enum.map(& &1.events) |> Enum.max() |> max(1)

    defp bar(_value, 0), do: 0
    defp bar(value, max), do: Float.round(value / max * 100, 1)

    defp number(n) when is_integer(n) do
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()
    end

    defp number(n), do: to_string(n)

    defp percent(rate) when is_float(rate), do: "#{Float.round(rate * 100, 1)}%"
    defp percent(_), do: "—"

    defp percent_number(value) when is_number(value), do: "#{value}%"
    defp percent_number(_), do: "—"

    defp duration(ms) when is_integer(ms) and ms >= 0 do
      seconds = div(ms, 1_000)
      if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    end

    defp duration(_), do: "—"

    @doc false
    def styles do
      Phoenix.HTML.raw("""
      .px-root{--px-bg:#fff;--px-fg:#111827;--px-muted:#6b7280;--px-line:#e5e7eb;
        --px-accent:#4f46e5;--px-accent-soft:#eef2ff;
        font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;
        color:var(--px-fg);background:var(--px-bg);padding:24px;max-width:1200px;margin:0 auto}
      @media (prefers-color-scheme:dark){.px-root{--px-bg:#0b0f19;--px-fg:#e5e7eb;
        --px-muted:#9ca3af;--px-line:#1f2937;--px-accent:#818cf8;--px-accent-soft:#1e1b4b}}
      .px-root h1{font-size:20px;margin:0;font-weight:650}
      .px-root h2{font-size:13px;margin:0 0 12px;font-weight:600;color:var(--px-muted);
        text-transform:uppercase;letter-spacing:.04em}
      .px-header{display:flex;justify-content:space-between;align-items:flex-start;
        gap:16px;flex-wrap:wrap;margin-bottom:20px}
      .px-site{margin:2px 0 0;color:var(--px-muted);font-size:13px}
      .px-ranges{display:flex;gap:4px}
      .px-range{padding:5px 12px;border:1px solid var(--px-line);background:transparent;
        color:var(--px-muted);border-radius:6px;cursor:pointer;font:inherit;font-size:13px}
      .px-range-on{background:var(--px-accent);border-color:var(--px-accent);color:#fff}
      .px-tiles{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
        margin-bottom:20px}
      .px-tile{border:1px solid var(--px-line);border-radius:10px;padding:14px}
      .px-tile-label{display:block;color:var(--px-muted);font-size:12px}
      .px-tile-value{display:block;font-size:24px;font-weight:650;margin-top:4px;
        font-variant-numeric:tabular-nums}
      .px-tile-note{display:block;color:var(--px-muted);font-size:11px;margin-top:4px}
      .px-card{border:1px solid var(--px-line);border-radius:10px;padding:16px;margin-bottom:16px}
      .px-grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
      .px-bars{list-style:none;margin:0;padding:0}
      .px-bars li,.px-funnel li{position:relative;display:flex;justify-content:space-between;
        gap:12px;padding:7px 10px;margin-bottom:2px;border-radius:6px;overflow:hidden}
      .px-bar{position:absolute;inset:0 auto 0 0;background:var(--px-accent-soft);z-index:0}
      .px-bar-label{position:relative;z-index:1;overflow:hidden;text-overflow:ellipsis;
        white-space:nowrap}
      .px-bar-value{position:relative;z-index:1;font-variant-numeric:tabular-nums;
        color:var(--px-muted);flex-shrink:0}
      .px-bar-value em{font-style:normal;margin-left:8px;color:var(--px-accent)}
      .px-funnel{list-style:none;margin:0 0 8px;padding:0}
      .px-table{width:100%;border-collapse:collapse}
      .px-table th{text-align:left;font-weight:500;color:var(--px-muted);font-size:12px;
        border-bottom:1px solid var(--px-line);padding:6px 8px}
      .px-table td{padding:6px 8px;border-bottom:1px solid var(--px-line)}
      .px-num{text-align:right;font-variant-numeric:tabular-nums}
      .px-chart{width:100%;height:120px;display:block}
      .px-chart-line{fill:none;stroke:var(--px-accent);stroke-width:2}
      .px-chart-area{fill:var(--px-accent-soft)}
      .px-chart-axis{display:flex;justify-content:space-between;color:var(--px-muted);
        font-size:11px;margin-top:6px}
      .px-empty,.px-hint{color:var(--px-muted);font-size:13px;margin:4px 0}
      .px-error{color:#b91c1c;background:#fef2f2;border:1px solid #fecaca;padding:10px 12px;
        border-radius:8px}
      .px-root textarea{width:100%;box-sizing:border-box;font:inherit;font-family:ui-monospace,
        monospace;font-size:13px;padding:8px;border:1px solid var(--px-line);border-radius:6px;
        background:transparent;color:inherit;margin-bottom:8px}
      .px-note{color:var(--px-accent);background:var(--px-accent-soft);border-radius:8px;
        padding:10px 12px;font-size:13px;margin:4px 0}
      .px-label{display:block;margin-bottom:14px}
      .px-label>.px-hint{display:block;margin:2px 0 4px}
      .px-check{display:block;margin-bottom:14px;color:var(--px-muted)}
      .px-root input[type=text],.px-root input[type=password],.px-root input[type=number]{
        width:100%;box-sizing:border-box;font:inherit;font-size:13px;padding:8px;margin-top:4px;
        border:1px solid var(--px-line);border-radius:6px;background:transparent;color:inherit}
      .px-root input:disabled,.px-root textarea:disabled{opacity:.55;cursor:not-allowed}
      .px-pill{display:inline-block;margin-left:8px;padding:1px 8px;border-radius:999px;
        border:1px solid var(--px-line);color:var(--px-muted);font-size:11px;
        text-transform:none;letter-spacing:0}
      .px-pill-on{border-color:var(--px-accent);color:var(--px-accent);
        background:var(--px-accent-soft)}
      .px-actions{display:flex;gap:8px;flex-wrap:wrap}
      .px-button-ghost{background:transparent;color:var(--px-accent);
        border:1px solid var(--px-line)}
      .px-button{padding:6px 14px;border:0;border-radius:6px;background:var(--px-accent);
        color:#fff;cursor:pointer;font:inherit;font-size:13px}
      """)
    end
  end
end
