defmodule Pixelex.Test.Endpoint do
  @moduledoc "A minimal Phoenix endpoint, so the dashboard and the LiveView hook can be driven for real."
  use Phoenix.Endpoint, otp_app: :pixelex

  @session_options [
    store: :cookie,
    key: "_pixelex_test",
    signing_salt: "pixelex-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(Pixelex.Plug)
  plug(Pixelex.Test.Router)

  def session_options, do: @session_options
end
