defmodule Pixelex.Destinations.HTTP do
  @moduledoc """
  The one HTTP call every destination makes, and the reasoning behind each of
  its three options.

  ## `retry: :transient`

  `Req` does not retry POST by default, and every conversion here is a POST. A
  single 502 from an ad platform silently drops the conversion that ad spend is
  optimised against. Retrying is safe precisely because every event carries a
  deterministic `event_id` derived from the row it describes, and all of these
  platforms deduplicate on it — a replay cannot double-count.

  ## Ten seconds

  These run inside an Oban job, not a request, so the ceiling exists to free
  the worker rather than to protect a page.

  ## Testing without a live ad account

  `:req_options` is merged into every request, which is how the suite asserts
  on exact payloads without an account:

      config :pixelex, req_options: [plug: {Req.Test, PixelexStub}]

  Worth having beyond tests: the payload shape is the part that fails silently.
  A wrong field name gets a `200` and matches nothing.

  ## A 2xx is not success

  Some platforms answer `200` with the error in the body — TikTok's
  `{"code": 40001}` is the standard trap — so each destination supplies its own
  `:success` predicate. Treating a 2xx as delivery is how a broken integration
  reports itself as healthy for a month.
  """
  require Logger

  @timeout 10_000

  @type result :: :ok | {:error, term()}

  @doc "POST `body` as JSON to `url`."
  @spec post(atom(), String.t(), map(), keyword()) :: result()
  def post(platform, url, body, opts \\ []) do
    if client?() do
      request(platform, url, body, opts)
    else
      Logger.warning(
        ~s([pixelex] the #{platform} destination needs {:req, "~> 0.5"} in your deps; skipping.)
      )

      {:error, :req_not_available}
    end
  end

  defp request(platform, url, body, opts) do
    headers = Keyword.get(opts, :headers, [])
    success = Keyword.get(opts, :success, &default_success/1)

    # apply/3, not Req.post/2: `req` is an optional dependency, so a direct call
    # makes the compiler warn about an undefined module for every consumer who
    # did not install it. The caller has already checked it is loaded.
    options =
      [json: body, headers: headers, receive_timeout: @timeout, retry: :transient] ++
        Application.get_env(:pixelex, :req_options, [])

    case apply(Req, :post, [url, options]) do
      {:ok, response} ->
        if success.(response) do
          :ok
        else
          Logger.warning(
            "[pixelex] #{platform} rejected an event -> #{response.status}: " <>
              inspect(truncate(response.body))
          )

          {:error, {platform, response.status, truncate(response.body)}}
        end

      {:error, reason} ->
        Logger.warning("[pixelex] #{platform} request failed: #{inspect(reason)}")
        {:error, {platform, reason}}
    end
  rescue
    e -> {:error, {platform, e}}
  end

  defp default_success(%{status: status}), do: status in 200..299

  # `req` is optional: a host that only wants first-party analytics should not
  # be made to pull an HTTP client. Resolved at runtime rather than compile
  # time so that adding it later does not require force-recompiling pixelex.
  defp client?, do: Code.ensure_loaded?(Req)

  # Platform error bodies can be enormous; the reason is always in the first
  # few hundred characters and the rest just fills the log.
  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 500)
end
