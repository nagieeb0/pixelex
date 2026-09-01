if Code.ensure_loaded?(Plug) do
  defmodule Pixelex.Plug.Cookies do
    @moduledoc """
    Read a cookie without caring whether the host fetched them.

    `conn.cookies` is `%Plug.Conn.Unfetched{}` until `fetch_cookies/2` runs, and
    indexing that **raises**. `is_map/1` does not save you: `Unfetched` is a
    struct and structs are maps.

    That combination cost this library a silent outage in testing — every
    request raised inside a rescue, the rescue swallowed it, and the app
    recorded nothing at all while looking completely healthy. An endpoint that
    never calls `fetch_cookies/2` is perfectly ordinary, so this has to be safe.
    """

    @doc "The cookie's value, or `nil` — including when cookies were never fetched."
    @spec get(Plug.Conn.t(), String.t()) :: String.t() | nil
    def get(%{cookies: %Plug.Conn.Unfetched{}}, _name), do: nil
    def get(%{cookies: cookies}, name) when is_map(cookies), do: cookies[name]
    def get(_conn, _name), do: nil

    @doc "The consent decision the host's banner recorded, from assigns or the cookie."
    @spec consent_decision(Plug.Conn.t()) :: String.t() | nil
    def consent_decision(conn) do
      # assigns first: a host that already resolved consent should not have its
      # answer second-guessed by a stale cookie.
      case conn.assigns[:pixelex_consent] do
        decision when is_binary(decision) ->
          decision

        _ ->
          get(conn, Application.get_env(:pixelex, :consent_cookie, "pixelex_consent"))
      end
    end
  end
end
