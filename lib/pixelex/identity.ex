defmodule Pixelex.Identity do
  @moduledoc """
  Who a visitor is, without storing anything on their device.

      visitor_id = base64url(first 64 bits of HMAC-SHA256(salt_of_day, site_id | ua | ip))

  ## Why HMAC and not a plain hash

  A plain `sha256(salt <> data)` is length-extendable and, worse, invites the
  concatenation bug below. HMAC is a keyed PRF and is what "keyed hash" should
  mean. Plausible uses SipHash for speed; `:crypto.mac/4` is stdlib, needs no
  dependency, and at even a thousand events a second the difference is far
  below the cost of the database write that follows it.

  ## Why the separator is load-bearing

  Without a delimiter, `site_id = "ab"` with `ua = "c"` and `site_id = "a"`
  with `ua = "bc"` hash identically. Two different visitors on two different
  sites become one person. The `|` costs nothing and closes it.

  ## 64 bits

  Truncated to 8 bytes. Collisions are a birthday problem at ~4 billion
  visitors *within one day*, since the salt rotates — comfortably beyond
  anything this library will see, and short enough to keep the index small on
  the table that takes every write.

  ## Both ids, every time

  `visitor/3` returns the id under today's salt **and** yesterday's. Session
  lookup needs both: at 00:00 UTC the salt changes and every open session would
  otherwise be attributed to a new person. See `Pixelex.Sessions.resolve/3`.
  """

  alias Pixelex.Identity.Salts

  @type ids :: %{id: String.t(), previous_id: String.t() | nil}

  @doc """
  The visitor's id under today's salt, and under yesterday's.

  `previous_id` is `nil` on a site's first day, when there is no yesterday.
  """
  @spec visitor(String.t(), String.t() | nil, String.t() | nil) :: ids()
  def visitor(site_id, user_agent, ip) do
    %{current: current, previous: previous} = Salts.get()

    %{
      id: hash(current, site_id, user_agent, ip),
      previous_id: previous && hash(previous, site_id, user_agent, ip)
    }
  end

  @doc """
  The id under one explicit salt. Exposed for tests that need to reason about a
  specific day rather than "now".
  """
  @spec hash(binary(), String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def hash(salt, site_id, user_agent, ip) do
    :crypto.mac(:hmac, :sha256, salt, [
      to_string(site_id),
      "|",
      to_string(user_agent),
      "|",
      to_string(ip)
    ])
    |> binary_part(0, 8)
    |> Base.url_encode64(padding: false)
  end
end
