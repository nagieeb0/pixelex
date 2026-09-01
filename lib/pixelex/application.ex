defmodule Pixelex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      Pixelex.Store.children() ++
        [
          Pixelex.Identity.Salts,
          Pixelex.RateLimit.Sweeper,
          Pixelex.Sessions,
          Pixelex.Ingest
        ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Pixelex.Supervisor)
    Pixelex.Enrich.warn_once()
    result
  end
end
