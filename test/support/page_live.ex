defmodule Pixelex.Test.PageLive do
  @moduledoc "A LiveView carrying the pixelex hook, for testing dead vs connected renders."
  use Phoenix.LiveView, layout: {Pixelex.Test.Layouts, :live}

  # No :site_id here on purpose: the realistic setup is one global
  # `config :pixelex, site_id:`, shared with Pixelex.Plug.
  on_mount(Pixelex.LiveView)

  def mount(_params, _session, socket), do: {:ok, assign(socket, :count, 0)}

  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, :tab, params["tab"])}

  def handle_event("go", %{"to" => to}, socket), do: {:noreply, push_patch(socket, to: to)}

  def handle_event("convert", _params, socket) do
    Pixelex.LiveView.track(socket, "booking_completed", %{"value" => 1})
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <main>
      <h1>page</h1>
      <p>tab: {@tab}</p>
      <button phx-click="go" phx-value-to="/live?tab=b">patch</button>
      <button phx-click="convert">convert</button>
    </main>
    """
  end
end

defmodule Pixelex.Test.NestedLive do
  @moduledoc "A LiveView with no handle_params/3, as a nested one has none."
  use Phoenix.LiveView, layout: {Pixelex.Test.Layouts, :live}

  on_mount(Pixelex.LiveView)

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns), do: ~H"<span>nested</span>"
end
