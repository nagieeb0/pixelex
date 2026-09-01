defmodule Pixelex.Enrich do
  @moduledoc """
  What the server already knows about a request, extracted.

  A Phoenix app gets the IP, the user agent, the `Referer`, the language and
  the privacy headers for free, on every request, before a single byte of
  JavaScript runs. That is most of an analytics record, and it is the reason
  pixelex is server-first: the JS tracker adds screen size, scroll depth and
  engagement time, and nothing else that matters.

  ## Bot filtering

  `ua_inspector` returns a distinct `%UAInspector.Result.Bot{}` for crawlers,
  which is the whole of bot detection here. Unfiltered, a busy site's "traffic"
  is substantially Googlebot, AhrefsBot and a long tail of scrapers, and every
  number derived from it is wrong in the same direction.

  ## Degrading without `ua_inspector`

  It is an optional dependency, because it pulls `hackney ~> 1.0` and hackney
  1.25.0 carries unpatched advisories with no fix in the 1.x line. Without it,
  `browser`/`os`/`device_type` are `nil` and bot detection falls back to a
  short substring list that catches the well-behaved crawlers and misses the
  rest. `mode/0` reports which is running; the installer adds the dependency by
  default and `warn_once/0` says so at boot when it is absent.
  """
  require Logger

  @ua_inspector? Code.ensure_loaded?(UAInspector)
  @ref_inspector? Code.ensure_loaded?(RefInspector)

  # Enough to catch crawlers that identify themselves honestly, which is most
  # of the volume. Not a substitute for the real database.
  @bot_substrings ~w(
    bot crawler spider crawl slurp curl wget python-requests scrapy
    headlesschrome phantomjs facebookexternalhit lighthouse pingdom
    uptimerobot gtmetrix semrush ahrefs mj12 dotbot petalbot bytespider
  )

  # ua_inspector calls curl, wget, python-requests, Go-http-client and okhttp
  # `type: "library"` rather than bots, because they are not crawlers — they
  # are scripts. For a pageview count the distinction does not matter: neither
  # is a person, and both inflate the same numbers. Verified against the real
  # database; nothing in the docs says this.
  @non_human_client_types ~w(library feed reader)

  @type device :: %{
          browser: String.t() | nil,
          os: String.t() | nil,
          device_type: String.t() | nil,
          client_type: String.t() | nil,
          bot?: boolean()
        }

  @doc "`:ua_inspector` when the real database is available, `:heuristic` when degraded."
  @spec mode() :: :ua_inspector | :heuristic
  def mode, do: if(@ua_inspector?, do: :ua_inspector, else: :heuristic)

  @doc """
  Browser, OS, device type and whether this is a crawler.

  Never raises: a user agent is attacker-controlled input, and the correct
  outcome for an unparseable one is an under-described event, not a failed
  request.
  """
  @spec device(String.t() | nil) :: device()
  def device(user_agent)

  def device(nil), do: empty()
  def device(""), do: empty()

  if @ua_inspector? do
    def device(user_agent) when is_binary(user_agent) do
      case UAInspector.parse(user_agent) do
        %UAInspector.Result.Bot{} ->
          %{empty() | bot?: true}

        %UAInspector.Result{client: client, os: os, device: device} ->
          client_type = type_of(client)

          %{
            browser: name_of(client),
            os: name_of(os),
            device_type: type_of(device),
            client_type: client_type,
            bot?: client_type in @non_human_client_types
          }

        _ ->
          heuristic(user_agent)
      end
    rescue
      # A missing database makes UAInspector raise. Fall back rather than fail
      # the request that was only trying to be counted.
      _ -> heuristic(user_agent)
    end

    defp name_of(%{name: name}) when is_binary(name) and name != "", do: name
    defp name_of(_), do: nil

    defp type_of(%{type: type}) when is_binary(type) and type != "", do: type
    defp type_of(_), do: nil
  else
    def device(user_agent) when is_binary(user_agent), do: heuristic(user_agent)
  end

  @doc """
  Is this user agent something other than a human in a browser?

  Covers crawlers and HTTP libraries alike. Asked by the **browser** ingest
  endpoint before it does any other work.

  Deliberately not asked by `Pixelex.track/3`: a mobile SDK sends `okhttp` or
  `Dart/3.x`, which are libraries by exactly this definition, and a server-side
  call was made on purpose by the host application. Filtering there would drop
  real events to catch traffic that never arrives that way.
  """
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(nil), do: false
  def bot?(""), do: false
  def bot?(user_agent) when is_binary(user_agent), do: device(user_agent).bot?

  @doc """
  Split a URL into the parts stored separately.

  `pathname` is stored without the query string: query strings carry click ids,
  session tokens and occasionally personal data, and a "top pages" report that
  lists ten thousand variants of `/product?utm_content=…` is not a report.
  The full URL is kept for attribution, which needs the parameters.
  """
  @spec url_parts(String.t() | nil) :: %{
          url: String.t() | nil,
          pathname: String.t() | nil,
          hostname: String.t() | nil
        }
  def url_parts(nil), do: %{url: nil, pathname: nil, hostname: nil}

  def url_parts(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{} = uri ->
        %{
          url: url,
          pathname: normalise_path(uri.path),
          hostname: uri.host && String.downcase(uri.host)
        }
    end
  rescue
    _ -> %{url: url, pathname: nil, hostname: nil}
  end

  def url_parts(_), do: %{url: nil, pathname: nil, hostname: nil}

  @doc "Logs once, at boot, when an optional enrichment dependency is missing."
  # Resolved at compile time. Written as a module attribute rather than
  # `mode() == :heuristic` because that comparison is between two compile-time
  # constants, which Dialyzer correctly flags as never true — and dialyxir
  # 1.4.7 cannot even format, let alone silence, an :exact_compare warning.
  @missing_deps if(@ua_inspector?,
                  do: [],
                  else: ["ua_inspector (browser/OS/device, and real bot filtering)"]
                ) ++
                  if(@ref_inspector?,
                    do: [],
                    else: ["ref_inspector (search/social/email referrer classification)"]
                  )

  @spec warn_once() :: :ok
  def warn_once do
    missing = @missing_deps

    if missing != [] do
      Logger.info("""
      [pixelex] running with reduced enrichment. Missing: #{Enum.join(missing, ", ")}.

          {:ref_inspector, "~> 2.0"},
          {:ua_inspector, "~> 3.0"}

      Then `mix ref_inspector.download` and `mix ua_inspector.download` — the
      databases are fetched, not bundled, and a release needs that step in its
      build. Everything works without them; attribution is simply coarser.
      """)
    end

    :ok
  end

  # Trailing slashes make /pricing and /pricing/ two rows in every report.
  defp normalise_path(nil), do: "/"
  defp normalise_path(""), do: "/"
  defp normalise_path("/"), do: "/"

  defp normalise_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp heuristic(user_agent) do
    downcased = String.downcase(user_agent)

    %{empty() | bot?: Enum.any?(@bot_substrings, &String.contains?(downcased, &1))}
  end

  defp empty,
    do: %{browser: nil, os: nil, device_type: nil, client_type: nil, bot?: false}
end
