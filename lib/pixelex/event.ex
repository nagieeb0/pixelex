defmodule Pixelex.Event do
  @moduledoc """
  The one thing pixelex stores.

  Web analytics, product analytics and ad attribution look like three products,
  but they differ only in which fields they read and where the row is forwarded.
  They are three views over this struct. Getting it right is the whole design;
  everything else is plumbing.

  ## The two fields you cannot add later

  `:v` and the `"px."` name prefix. A schema version lets a future reader tell a
  v1 row from a v2 row without guessing, and a reserved namespace lets pixelex
  introduce `px.pageview` in a release without colliding with an event a host app
  already named. Both are free today and unfixable once rows exist — Segment,
  Snowplow and PostHog all reserve a prefix, and PostHog's `$` came before their
  data did.

  ## Two timestamps

  `:timestamp` is stamped by the server and is authoritative. `:client_ts` is
  what the browser claimed, and browsers lie — clock skew of hours is ordinary.
  Keeping both lets `skew_corrected/2` recover the real client time using
  Segment's formula, and lets a query ignore the client's opinion entirely.

  ## Limits

  Names are capped at 120 characters and URLs/referrers at 2000 bytes, matching
  Plausible's ingest. These are not arbitrary: the fields are written from an
  unauthenticated endpoint, and a column with no ceiling is a disk-filling
  primitive handed to anyone who can find the URL.
  """

  @schema_version 1

  @name_max 120
  @url_max 2_000
  @reserved_prefix "px."

  @type render :: :dead | :connected | :client | :server

  @type t :: %__MODULE__{
          id: String.t(),
          v: pos_integer(),
          site_id: String.t(),
          name: String.t(),
          timestamp: DateTime.t(),
          client_ts: DateTime.t() | nil,
          visitor_id: String.t() | nil,
          session_id: String.t() | nil,
          user_id: String.t() | nil,
          url: String.t() | nil,
          pathname: String.t() | nil,
          hostname: String.t() | nil,
          referrer: String.t() | nil,
          attribution: map() | nil,
          country: String.t() | nil,
          region: String.t() | nil,
          city: String.t() | nil,
          browser: String.t() | nil,
          os: String.t() | nil,
          device_type: String.t() | nil,
          render: render() | nil,
          props: map()
        }

  defstruct id: nil,
            v: @schema_version,
            site_id: nil,
            name: nil,
            timestamp: nil,
            client_ts: nil,
            visitor_id: nil,
            session_id: nil,
            user_id: nil,
            url: nil,
            pathname: nil,
            hostname: nil,
            referrer: nil,
            attribution: nil,
            country: nil,
            region: nil,
            city: nil,
            browser: nil,
            os: nil,
            device_type: nil,
            render: nil,
            props: %{}

  @doc "The schema version stamped on every event this build writes."
  def schema_version, do: @schema_version

  @doc "The namespace pixelex reserves for its own event names."
  def reserved_prefix, do: @reserved_prefix

  @doc """
  Builds a validated event, filling in `:id` and `:timestamp` when absent.

  Returns `{:ok, event}` or `{:error, reason}`. Every caller of this is on a path
  where analytics must never be the reason a request fails, so callers match on
  the error and drop — they do not raise.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    with {:ok, site_id} <- validate_site_id(attrs[:site_id]),
         {:ok, name} <- validate_name(attrs[:name]) do
      {:ok,
       %__MODULE__{
         id: attrs[:id] || uuid7(),
         v: @schema_version,
         site_id: site_id,
         name: name,
         timestamp: attrs[:timestamp] || DateTime.utc_now(),
         client_ts: attrs[:client_ts],
         visitor_id: attrs[:visitor_id],
         session_id: attrs[:session_id],
         user_id: attrs[:user_id],
         url: truncate(attrs[:url], @url_max),
         pathname: truncate(attrs[:pathname], @url_max),
         hostname: truncate(attrs[:hostname], 255),
         referrer: truncate(attrs[:referrer], @url_max),
         attribution: attrs[:attribution],
         country: truncate(attrs[:country], 2),
         region: truncate(attrs[:region], 64),
         city: truncate(attrs[:city], 128),
         browser: truncate(attrs[:browser], 64),
         os: truncate(attrs[:os], 64),
         device_type: truncate(attrs[:device_type], 32),
         render: validate_render(attrs[:render]),
         props: props(attrs[:props])
       }}
    end
  end

  @doc """
  The real client time, correcting for a skewed browser clock.

      timestamp = received_at - (sent_at - originally_created_at)

  Segment's formula. `sent_at` and `client_ts` come from the same wrong clock, so
  their difference is accurate even when neither value is. Falls back to the
  server timestamp when the client sent nothing.
  """
  @spec skew_corrected(t(), DateTime.t() | nil) :: DateTime.t()
  def skew_corrected(%__MODULE__{client_ts: nil} = event, _sent_at), do: event.timestamp
  def skew_corrected(%__MODULE__{} = event, nil), do: event.timestamp

  def skew_corrected(%__MODULE__{} = event, %DateTime{} = sent_at) do
    skew_ms = DateTime.diff(sent_at, event.client_ts, :millisecond)
    DateTime.add(event.timestamp, -skew_ms, :millisecond)
  end

  @doc """
  A UUIDv7 as a 36-character string.

  v7 over v4 because the first 48 bits are a millisecond timestamp, so ids sort
  in insertion order. That turns the primary-key index from a random-write
  hotspot into an append, which is the difference between a b-tree that stays
  cache-resident and one that does not — on the table that takes every write in
  the system.

  Written here rather than pulled in: it is fifteen lines of `:crypto`, and the
  alternative is a dependency in every consumer's tree for those fifteen lines.

  Layout per RFC 9562: 48-bit big-endian unix ms, 4-bit version `0b0111`,
  12 bits random, 2-bit variant `0b10`, 62 bits random.
  """
  @spec uuid7() :: String.t()
  def uuid7 do
    # 10 bytes = 80 bits; we need 12 + 62 = 74 and discard the remaining 6.
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    ms = System.system_time(:millisecond)

    encode_hex(<<ms::big-unsigned-48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>)
  end

  # --- validation -----------------------------------------------------------

  defp validate_site_id(id) when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 255,
    do: {:ok, id}

  defp validate_site_id(_), do: {:error, :invalid_site_id}

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      String.length(trimmed) > @name_max -> {:error, :name_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp validate_name(name) when is_atom(name) and not is_nil(name),
    do: validate_name(Atom.to_string(name))

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_render(r) when r in [:dead, :connected, :client, :server], do: r
  defp validate_render(_), do: nil

  # Props arrive from the wire. A map with unbounded depth serialises to
  # unbounded JSON, so values are flattened to scalars and the map is capped.
  # Silently dropping the excess beats rejecting the event: the pageview is
  # still true even when the 51st custom property is not recorded.
  defp props(p) when is_map(p) do
    p
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.take(50)
    |> Map.new(fn {k, v} -> {to_string(k), scalar(v)} end)
  end

  defp props(_), do: %{}

  defp scalar(v) when is_binary(v), do: String.slice(v, 0, 500)
  defp scalar(v) when is_number(v) or is_boolean(v), do: v
  defp scalar(v) when is_atom(v), do: Atom.to_string(v)
  defp scalar(v), do: v |> inspect() |> String.slice(0, 500)

  defp truncate(v, n) when is_binary(v), do: binary_part(v, 0, min(byte_size(v), n))
  defp truncate(v, n) when is_atom(v) and not is_nil(v), do: truncate(Atom.to_string(v), n)
  defp truncate(_, _), do: nil

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Never String.to_atom/1 on wire data — it grows the atom table without bound
  # and the table is never garbage collected. Unknown keys become :__unknown__
  # and are ignored by new/1.
  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__unknown__
  end

  defp encode_hex(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    Base.encode16(a, case: :lower) <>
      "-" <>
      Base.encode16(b, case: :lower) <>
      "-" <>
      Base.encode16(c, case: :lower) <>
      "-" <>
      Base.encode16(d, case: :lower) <> "-" <> Base.encode16(e, case: :lower)
  end
end
