if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Pixelex.Dashboard.Settings do
    @moduledoc """
    Where a tenant sets up their own pixels, without a deploy and without you.

        scope "/admin" do
          pipe_through [:browser, :require_admin]
          pixelex_dashboard "/analytics"
          pixelex_settings "/analytics/settings"
        end

    ## Paste anything

    The form does not ask a marketer to know the difference between a *pixel
    code*, a *measurement ID* and an *ad account ID*. It takes the block of
    JavaScript their ad platform told them to install, finds the id inside it
    and fills in the right field on the right card —
    `Pixelex.Destinations.Detect` is the whole trick, and it works in the
    individual fields too, so pasting a snippet into *Pixel ID* is fine.

    ## Test is the feature

    Wrong credentials do not fail loudly. They produce a silent gap in
    reporting that somebody notices three weeks later while wondering why
    conversions fell off. So every configured card gets a **Test** button that
    sends a real `page_view` through the platform's live API and prints what
    came back. Setup is not "saved", it is "verified".

    ## Secrets go in and do not come out

    An access token is written, never rendered. The field shows `Set` or
    `Not set`; leaving it blank on save keeps the stored value, and *Disconnect*
    is how you remove one. With `config :pixelex, secret_key:` set they are
    encrypted at rest too — see `Pixelex.Secrets`.

    ## It has no authentication, and here that matters more

    Like the dashboard, this inherits the pipeline you scope it in. Unlike the
    dashboard it *writes*, so if you serve several tenants from one host, pin
    the site rather than letting `?site=` choose it:

        pixelex_settings "/analytics/settings", site_id: "acme"

    or pass an `:on_mount` hook that checks the current user against the site
    they asked for. With a custom-domain product the host *is* the tenant and
    the default is already right.
    """
    use Phoenix.LiveView

    alias Pixelex.{Destinations, Secrets, Sites}
    alias Pixelex.Destinations.Detect

    @impl true
    def mount(params, session, socket) do
      site_id = session["pixelex_site_id"] || params["site"] || host(socket)

      {:ok,
       socket
       |> assign(:site_id, site_id)
       |> assign(:page_title, "Analytics settings")
       |> assign(:paste, "")
       |> assign(:detected, %{})
       |> assign(:flash_note, nil)
       |> assign(:results, %{})
       |> load()}
    end

    # --- events ---------------------------------------------------------------

    @impl true
    def handle_event("detect", %{"paste" => text}, socket) do
      detected = Detect.detect(text)

      {:noreply,
       socket
       |> assign(:paste, text)
       |> assign(:detected, detected)
       |> assign(:values, merge_detected(socket.assigns.values, detected))}
    end

    def handle_event("save_platform", %{"platform" => platform} = params, socket) do
      site = socket.assigns.site_id
      attrs = Map.get(params, "credentials", %{})

      case Destinations.put_credentials(site, safe_platform(platform), attrs) do
        {:ok, _site} ->
          {:noreply,
           socket
           |> note("Saved #{platform}.")
           |> assign(:paste, "")
           |> assign(:detected, %{})
           |> load()}

        {:error, reason} ->
          {:noreply, note(socket, "Could not save #{platform}: #{explain(reason)}")}
      end
    end

    def handle_event("test_platform", %{"platform" => platform}, socket) do
      atom = safe_platform(platform)
      result = Destinations.test(socket.assigns.site_id, atom)

      {:noreply, assign(socket, :results, Map.put(socket.assigns.results, atom, result))}
    end

    def handle_event("disconnect", %{"platform" => platform}, socket) do
      atom = safe_platform(platform)

      case Destinations.delete_credentials(socket.assigns.site_id, atom) do
        {:ok, _site} ->
          {:noreply,
           socket
           |> note("Disconnected #{platform}.")
           |> assign(:results, Map.delete(socket.assigns.results, atom))
           |> load()}

        {:error, reason} ->
          {:noreply, note(socket, "Could not disconnect #{platform}: #{explain(reason)}")}
      end
    end

    def handle_event("save_site", params, socket) do
      attrs = %{
        domain: blank_to_nil(params["domain"]),
        allowed_events: split_events(params["allowed_events"]),
        allow_any_event: params["allow_any_event"] == "on",
        retention_days: to_int(params["retention_days"])
      }

      case Sites.update(socket.assigns.site_id, attrs) do
        {:ok, _site} -> {:noreply, socket |> note("Saved site settings.") |> load()}
        {:error, reason} -> {:noreply, note(socket, "Could not save: #{explain(reason)}")}
      end
    end

    # --- data -----------------------------------------------------------------

    defp load(socket) do
      site_id = socket.assigns.site_id
      site = Sites.get(site_id)
      config_defined? = not is_nil(Sites.configured(site_id))
      stored = (site && site.destinations) || %{}

      socket
      |> assign(:site, site)
      |> assign(:config_defined?, config_defined?)
      |> assign(:cards, Destinations.configurable())
      |> assign(:stored, stored)
      |> assign(:values, values(stored))
      |> assign(:load_error, nil)
    rescue
      e -> assign(socket, load_error: Exception.message(e), cards: [], stored: %{}, values: %{})
    end

    # Non-secret values are shown back so an id can be corrected in place.
    #
    # Built from `fields/0` rather than from what happens to be in the column:
    # a stored key that no destination declares is never rendered. Otherwise a
    # platform removed from `config :pixelex, destinations:` would leave its
    # access token behind as an undeclared key with nothing marking it secret.
    defp values(stored) do
      for {module, fields} <- Destinations.configurable(), into: %{} do
        credentials = Map.get(stored, to_string(module.name()), %{})

        shown =
          for %{key: key} = field <- fields,
              field[:secret] != true,
              value = credentials[to_string(key)],
              into: %{},
              do: {to_string(key), render_value(value)}

        {module.name(), shown}
      end
    end

    defp render_value(v) when is_map(v) do
      Enum.map_join(v, "\n", fn {event, id} -> "#{event}=#{id}" end)
    end

    defp render_value(v) when is_binary(v), do: v
    defp render_value(v), do: to_string(v)

    defp merge_detected(values, detected) do
      Enum.reduce(detected, values, fn {platform, creds}, acc ->
        current = Map.get(acc, platform, %{})
        found = Map.new(creds, fn {k, v} -> {to_string(k), v} end)
        Map.put(acc, platform, Map.merge(found, current, fn _k, new, old -> old || new end))
      end)
    end

    # --- helpers --------------------------------------------------------------

    # to_existing_atom against the platforms actually loaded: a form field is
    # user input, and this one is used as a map key.
    defp safe_platform(name) when is_atom(name), do: name

    defp safe_platform(name) when is_binary(name) do
      Enum.find_value(Destinations.modules(), :__unknown__, fn module ->
        if to_string(module.name()) == name, do: module.name()
      end)
    end

    defp note(socket, message), do: assign(socket, :flash_note, message)

    defp explain(:config_defined),
      do: "this site comes from `config :pixelex, sites:`, which the database cannot override."

    defp explain(:unknown_platform), do: "no such destination."
    defp explain(%{__exception__: true} = e), do: Exception.message(e)
    defp explain(other), do: inspect(other)

    defp split_events(nil), do: []

    defp split_events(raw) do
      raw
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.uniq()
      |> Enum.take(200)
    end

    defp blank_to_nil(nil), do: nil

    defp blank_to_nil(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end

    defp to_int(nil), do: nil

    defp to_int(value) do
      case Integer.parse(String.trim(value)) do
        {int, _} when int > 0 -> int
        _ -> nil
      end
    end

    defp host(socket) do
      case get_connect_info(socket, :uri) do
        %URI{host: host} when is_binary(host) -> host
        _ -> "localhost"
      end
    end

    defp configured?(module, stored) do
      case stored[to_string(module.name())] do
        creds when is_map(creds) ->
          required =
            for %{key: k} = f <- module.fields(), f[:optional] != true, do: to_string(k)

          Enum.all?(required, fn key ->
            case creds[key] do
              value when is_binary(value) -> value != ""
              value when is_map(value) -> map_size(value) > 0
              _ -> false
            end
          end)

        _ ->
          false
      end
    end

    # --- render ---------------------------------------------------------------

    @impl true
    def render(assigns) do
      ~H"""
      <div class="px-root">
        <style>
          <%= Pixelex.Dashboard.Live.styles() %>
        </style>

        <header class="px-header">
          <div>
            <h1>Analytics settings</h1>
            <p class="px-site">{@site_id}</p>
          </div>
        </header>

        <p :if={@flash_note} class="px-note">{@flash_note}</p>
        <p :if={@load_error} class="px-error">{@load_error}</p>

        <p :if={@config_defined?} class="px-note">
          This site is defined in <code>config :pixelex, sites:</code>, which always wins
          over the database. Edit it there — saving here would be a button that does nothing.
        </p>

        <section class="px-card">
          <h2>Paste anything</h2>
          <p class="px-hint">
            The snippet your ad platform gave you, or just the id. It gets read and dropped
            into the right box below — nothing is saved until you press Save on a card.
          </p>
          <form id="px-paste" phx-change="detect">
            <textarea
              name="paste"
              rows="3"
              placeholder={"<script>!function(f,b,e,v,n,t,s){…}(window,document,…);\nfbq('init', '1234567890123456');</script>"}
              phx-debounce="300"
            >{@paste}</textarea>
          </form>
          <p :if={@detected != %{}} class="px-note">
            Found: {Enum.map_join(@detected, ", ", fn {platform, creds} ->
              "#{platform} (#{Enum.map_join(creds, ", ", fn {k, _} -> to_string(k) end)})"
            end)}
          </p>
        </section>

        <div class="px-grid">
          <.platform_card
            :for={{module, fields} <- @cards}
            module={module}
            fields={fields}
            values={Map.get(@values, module.name(), %{})}
            stored={Map.get(@stored, to_string(module.name()), %{})}
            configured={configured?(module, @stored)}
            result={Map.get(@results, module.name())}
            locked={@config_defined?}
          />
        </div>

        <section class="px-card">
          <h2>Site</h2>
          <form id="px-site" phx-submit="save_site">
            <label class="px-label">
              Domain
              <input
                type="text"
                name="domain"
                value={@site && @site.domain}
                placeholder="shop.example.com"
                disabled={@config_defined?}
              />
            </label>

            <label class="px-label">
              Allowed event names
              <span class="px-hint">
                What a browser is permitted to send. One per line or comma-separated.
                <code>px.pageview</code> is always allowed.
              </span>
              <textarea name="allowed_events" rows="4" disabled={@config_defined?}>{@site && Enum.join(@site.allowed_events, "\n")}</textarea>
            </label>

            <label class="px-check">
              <input
                type="checkbox"
                name="allow_any_event"
                checked={@site && @site.allow_any_event}
                disabled={@config_defined?}
              /> Accept any event name
              <span class="px-hint">
                Only for sites that never emit events from a browser. An open endpoint with
                no allowlist is a table anyone can fill.
              </span>
            </label>

            <label class="px-label">
              Retention (days)
              <input
                type="number"
                name="retention_days"
                min="1"
                value={@site && @site.retention_days}
                placeholder="90"
                disabled={@config_defined?}
              />
            </label>

            <button type="submit" class="px-button" disabled={@config_defined?}>Save</button>
          </form>
        </section>

        <p class="px-hint">
          <span :if={Secrets.enabled?()}>Credentials are encrypted at rest.</span>
          <span :if={not Secrets.enabled?()}>
            Credentials are stored as given. Set <code>config :pixelex, secret_key:</code>
            to encrypt them — see <code>Pixelex.Secrets</code>.
          </span>
        </p>
      </div>
      """
    end

    attr(:module, :atom, required: true)
    attr(:fields, :list, required: true)
    attr(:values, :map, required: true)
    attr(:stored, :map, required: true)
    attr(:configured, :boolean, required: true)
    attr(:result, :any, default: nil)
    attr(:locked, :boolean, default: false)

    defp platform_card(assigns) do
      ~H"""
      <section class="px-card">
        <h2>
          {@module.name()}
          <span class={["px-pill", @configured && "px-pill-on"]}>
            {if @configured, do: "connected", else: "not set up"}
          </span>
        </h2>

        <form id={"px-#{@module.name()}"} phx-submit="save_platform">
          <input type="hidden" name="platform" value={@module.name()} />

          <label :for={field <- @fields} class="px-label">
            {field.label}
            <span :if={field[:secret]} class="px-pill">
              {if present?(@stored[to_string(field.key)]), do: "set", else: "not set"}
            </span>

            <textarea
              :if={field[:type] == :map}
              name={"credentials[#{field.key}]"}
              rows="3"
              disabled={@locked}
            >{@values[to_string(field.key)]}</textarea>

            <input
              :if={field[:type] != :map}
              type={if field[:secret], do: "password", else: "text"}
              name={"credentials[#{field.key}]"}
              value={field[:secret] != true && @values[to_string(field.key)]}
              placeholder={field[:placeholder] || (field[:secret] && "leave blank to keep")}
              autocomplete="off"
              disabled={@locked}
            />

            <span :if={field[:hint]} class="px-hint">{field.hint}</span>
          </label>

          <div class="px-actions">
            <button type="submit" class="px-button" disabled={@locked}>Save</button>
            <button
              :if={@configured}
              type="button"
              class="px-button px-button-ghost"
              phx-click="test_platform"
              phx-value-platform={@module.name()}
            >
              Test
            </button>
            <button
              :if={@configured and not @locked}
              type="button"
              class="px-button px-button-ghost"
              phx-click="disconnect"
              phx-value-platform={@module.name()}
            >
              Disconnect
            </button>
          </div>
        </form>

        <p :if={@result == :ok} class="px-note">
          Accepted. A test <code>page_view</code> reached {@module.name()}.
        </p>
        <p :if={match?({:error, _}, @result)} class="px-error">
          {test_error(@result)}
        </p>
      </section>
      """
    end

    defp present?(value) when is_binary(value), do: value != ""
    defp present?(value) when is_map(value), do: map_size(value) > 0
    defp present?(_), do: false

    defp test_error({:error, :not_configured}), do: "Fill in and save the fields above first."
    defp test_error({:error, :req_not_available}), do: ~s(Add {:req, "~> 0.5"} to your deps.)
    defp test_error({:error, %{__exception__: true} = e}), do: Exception.message(e)
    defp test_error({:error, reason}), do: "Rejected: #{inspect(reason)}"
  end
end
