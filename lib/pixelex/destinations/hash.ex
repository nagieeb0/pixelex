defmodule Pixelex.Destinations.Hash do
  @moduledoc """
  SHA-256 of normalised personal data, per each platform's own rules.

  Ad platforms match a server-side conversion to a user by comparing hashes, so
  the hash has to be byte-identical to the one they computed from their own
  copy of the same fact. That makes normalisation the whole job: `" Ali@Ex.COM"`
  and `"ali@ex.com"` are the same person and must produce the same digest, and
  a leading `+` on a phone number changes the answer.

  ## The platforms disagree, and it matters

  | | phone |
  |---|---|
  | Meta, Snapchat, Pinterest, Reddit | digits only — `+20 100 123 4567` → `201001234567` |
  | TikTok | E.164, the `+` **kept** — `+201001234567` |

  This is exactly why the raw value travels to the worker and is hashed at the
  edge of each client, rather than hashed once at enqueue: one shared digest
  cannot satisfy both, and hashing early would silently break TikTok matching
  in a way no error would ever report.

  ## Raw values never leave the box

  `email`, `phone`, names, city, state, zip, country and external ids are
  hashed before egress. `ip`, `user_agent` and click ids are match keys the
  platforms want in the clear, and pass through untouched.
  """

  @doc "Lower-cased, trimmed, SHA-256 hex."
  @spec email(String.t() | nil) :: String.t() | nil
  def email(value), do: once(value, &digest(normalise_text(&1)))

  @doc "Digits only, SHA-256 hex. Meta, Snapchat, Pinterest and Reddit."
  @spec phone_digits(String.t() | nil) :: String.t() | nil
  def phone_digits(value), do: once(value, &digest(strip(&1, ~r/[^0-9]/)))

  @doc "E.164 with the leading `+` preserved, SHA-256 hex. TikTok only."
  @spec phone_e164(String.t() | nil) :: String.t() | nil
  def phone_e164(value), do: once(value, &digest(strip(&1, ~r/[^0-9+]/)))

  @doc """
  Reddit's email rule, which is nobody else's.

  Lower-case, then **strip dots from the local part** and **drop everything
  after a `+`**, then hash. Reddit's own published vector:

      alice@example.com
      Al.ice+Apple@Example.Com

  both produce `ff8d9819fc0e12bf…`. Meta, Pinterest and TikTok do none of this
  — they hash the address as written, lower-cased. Using the wrong rule
  produces a valid request, a 200, and no matches, which is the failure this
  library keeps having to design around.
  """
  @spec email_reddit(String.t() | nil) :: String.t() | nil
  def email_reddit(value) do
    once(value, fn raw ->
      raw
      |> normalise_text()
      |> case do
        nil ->
          nil

        address ->
          case String.split(address, "@", parts: 2) do
            [local, domain] ->
              local
              |> String.split("+", parts: 2)
              |> hd()
              |> String.replace(".", "")
              |> Kernel.<>("@" <> domain)
              |> digest()

            _ ->
              digest(address)
          end
      end
    end)
  end

  @doc "Lower-cased, trimmed, SHA-256 hex. Names, cities, countries, external ids."
  @spec text(String.t() | nil) :: String.t() | nil
  def text(value), do: once(value, &digest(normalise_text(&1)))

  @doc "Lower-cased, trimmed, non-empty — or nil. Normalisation without hashing."
  @spec normalise_text(term()) :: String.t() | nil
  def normalise_text(value) do
    case presence(value) do
      nil -> nil
      v -> v |> to_string() |> String.trim() |> String.downcase() |> presence()
    end
  end

  @doc "SHA-256 hex of an already-normalised value; `nil` passes through."
  @spec digest(String.t() | nil) :: String.t() | nil
  def digest(nil), do: nil

  def digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc """
  Does this already look like a SHA-256 digest?

  Some hosts store a hashed email and pass it straight through. Hashing a
  64-character hex string a second time produces a digest that matches nothing,
  and nothing anywhere reports an error — the conversions simply stop
  attributing, which is the most expensive kind of silence in this library.
  """
  @spec hashed?(term()) :: boolean()
  def hashed?(value) when is_binary(value), do: value =~ ~r/^[a-fA-F0-9]{64}$/
  def hashed?(_), do: false

  @doc "Hash with `fun`, unless the value already is a digest."
  @spec once(term(), (String.t() -> String.t() | nil)) :: String.t() | nil
  def once(value, fun) do
    cond do
      presence(value) == nil -> nil
      hashed?(value) -> String.downcase(value)
      true -> fun.(to_string(value))
    end
  end

  @doc "Drop nil and empty values. Platforms reject empty match keys."
  @spec compact(map()) :: map()
  def compact(map) when is_map(map),
    do: Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" or v == [] or v == %{} end)

  defp strip(value, pattern) do
    value |> to_string() |> String.replace(pattern, "") |> presence()
  end

  defp presence(v) when v in [nil, ""], do: nil
  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(v), do: v
end
