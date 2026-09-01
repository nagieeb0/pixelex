defmodule Pixelex.Test.Repo do
  @moduledoc "Stand-in for a host application's repo, for integration tests."
  use Ecto.Repo, otp_app: :pixelex, adapter: Ecto.Adapters.Postgres
end
