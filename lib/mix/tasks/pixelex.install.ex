defmodule Mix.Tasks.Pixelex.Install do
  @moduledoc """
  Generate the migration and print the wiring for this application.

      mix pixelex.install

  Deliberately not an Igniter installer. Igniter would patch the endpoint and
  router automatically, and it would also mean every consumer of a small
  analytics library inherits a code-generation framework. The wiring is six
  lines; printing them and letting you paste them is a better trade, and it
  leaves you knowing what changed.

  ## Options

    * `--repo MyApp.Repo` — otherwise inferred from the application
    * `--no-migration` — print the wiring only
  """
  @shortdoc "Generate the pixelex migration and print the wiring"
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [repo: :string, migration: :boolean])

    app = Mix.Project.config()[:app]
    repo = opts[:repo] || infer_repo(app)

    if Keyword.get(opts, :migration, true), do: generate_migration(repo)

    Mix.shell().info(instructions(app, repo))
  end

  defp generate_migration(repo) do
    path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(path)

    if Enum.any?(File.ls!(path), &String.contains?(&1, "add_pixelex")) do
      Mix.shell().info([:yellow, "* skipped ", :reset, "a pixelex migration already exists"])
    else
      file = Path.join(path, "#{timestamp()}_add_pixelex.exs")

      File.write!(file, """
      defmodule #{inspect(repo)}.Migrations.AddPixelex do
        use Ecto.Migration

        def up, do: Pixelex.Migration.up()
        def down, do: Pixelex.Migration.down()
      end
      """)

      Mix.shell().info([:green, "* creating ", :reset, file])
    end
  end

  defp instructions(app, repo) do
    """

    #{IO.ANSI.bright()}Wiring#{IO.ANSI.reset()}

    1. config/config.exs

        config :pixelex,
          repo: #{inspect(repo)},
          # One site, declared in code — no database row needed to start.
          # A multi-tenant app uses the pixelex_sites table instead.
          sites: %{
            "example.com" => [allowed_events: ~w(signup_click contact_click)]
          }

    2. lib/#{app}_web/endpoint.ex — after `plug Plug.Static`

        plug Pixelex.Plug

    3. lib/#{app}_web/router.ex

        import Pixelex.Router

        pipeline :browser do
          # ... your existing plugs, after fetch_session
          plug Pixelex.Plug.Session
        end

        pixelex_ingest "/px"

        scope "/admin" do
          pipe_through [:browser, :your_admin_auth]
          pixelex_dashboard "/analytics"
        end

    4. For LiveView, in the same router:

        live_session :default, on_mount: [Pixelex.LiveView] do
          # your live routes
        end

       and in the endpoint, so the socket can see the request:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [
            connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]
          ]

    5. Behind a proxy — Fly, Cloudflare, Heroku, nginx — name the header, or
       every visitor hashes to the load balancer and your site has one visitor:

        config :pixelex, client_ip_header: "fly-client-ip"

    6. Keep partitions ahead of the calendar. A range-partitioned table with no
       partition covering today rejects every insert, and ingestion stops at
       midnight on the first of the month:

        # with Oban
        {"0 3 * * *", #{Macro.camelize(to_string(app))}.PixelexMaintenance}

        defmodule #{Macro.camelize(to_string(app))}.PixelexMaintenance do
          use Oban.Worker

          def perform(_job) do
            Pixelex.Partitions.ensure(2)
            Pixelex.Partitions.drop_expired()
            :ok
          end
        end

    7. Strongly recommended, for referrer classification and real bot filtering:

        {:ref_inspector, "~> 2.0"},
        {:ua_inspector, "~> 3.0"}

       then `mix ref_inspector.download` and `mix ua_inspector.download` —
       #{IO.ANSI.bright()}including in your Dockerfile#{IO.ANSI.reset()}, before
       `mix release`. Those databases are downloaded, not bundled.

    8. Optionally, the browser tracker. Not needed for page views:

        <script defer src="/px/pixelex.js" data-site="example.com"></script>

    Then `mix ecto.migrate`.
    """
  end

  defp infer_repo(app) do
    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] -> repo
      _ -> Module.concat([Macro.camelize(to_string(app)), "Repo"])
    end
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss])
    |> List.to_string()
  end
end
