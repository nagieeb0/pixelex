defmodule Pixelex.Test.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Pixelex.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {Pixelex.Test.Layouts, :root})
    plug(Pixelex.Plug.Session)
  end

  pixelex_ingest("/px")

  scope "/" do
    pipe_through(:browser)

    live("/live", Pixelex.Test.PageLive)
    pixelex_dashboard("/analytics", site_id: "dash.test")
  end
end
