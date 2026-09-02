defmodule Pixelex.Destinations.Detect do
  @moduledoc """
  Turn whatever a marketer has on their clipboard into credentials.

  ## The problem this solves

  A settings form that asks for `pixel_code` on one row, `measurement_id` on
  the next and `ad_account_id` on the third is asking the person filling it in
  to already know the answer. What they actually have is the block of
  JavaScript Events Manager told them to paste into their site — and every one
  of those blocks contains the id, in a position a regex can reach.

      Detect.detect(~s|<script>fbq('init', '1234567890123456');</script>|)
      #=> %{meta: %{pixel_id: "1234567890123456"}}

      Detect.detect("G-ABC1234XYZ")
      #=> %{ga4: %{measurement_id: "G-ABC1234XYZ"}}

  ## Two entry points

  `detect/1` scans free text and reports every platform it recognises — the
  "paste anything" box. `clean/3` knows which platform and field it is filling
  and pulls that one value out, so pasting a snippet into the *Pixel ID* field
  works exactly as well as typing the id.

  ## What it deliberately does not detect

  Access tokens, API secrets and Pinterest ad-account ids have no distinguishing
  shape — Meta's `EAA…` prefix is the one exception and it is here. Guessing at
  the rest would mean writing a token into the wrong platform's row, which fails
  as a `401` weeks later with nothing pointing at the cause. Anything ambiguous
  stays a field the human fills in.

  Detection is a *suggestion*: it populates the form, the human saves it.
  """

  # Ordered. The snippet forms come first, so a paste containing both a snippet
  # and a bare number resolves to the one the platform actually wrote.
  @patterns [
    # --- Meta ---------------------------------------------------------------
    {:meta, :pixel_id, ~r/fbq\s*\(\s*['"]init['"]\s*,\s*['"](\d{8,20})['"]/},
    {:meta, :pixel_id, ~r/\bpixel[_\s-]?id["'\s:=]+(\d{15,16})\b/i},
    {:meta, :pixel_id, ~r/\A(\d{15,16})\z/},
    # Long-lived system-user tokens are the ones that end up in a settings
    # screen, and they all carry Meta's prefix.
    {:meta, :access_token, ~r/\b(EAA[A-Za-z0-9_\-]{40,})/},

    # --- GA4 ----------------------------------------------------------------
    {:ga4, :measurement_id, ~r/\b(G-[A-Z0-9]{6,12})\b/},

    # --- TikTok -------------------------------------------------------------
    {:tiktok, :pixel_code, ~r/ttq\.load\s*\(\s*['"]([A-Z0-9]{15,25})['"]/},
    {:tiktok, :pixel_code, ~r/\A([A-Z0-9]{20})\z/},

    # --- Snapchat -----------------------------------------------------------
    {:snapchat, :pixel_id, ~r/snaptr\s*\(\s*['"]init['"]\s*,\s*['"]([0-9a-f-]{36})['"]/i},
    {:snapchat, :pixel_id,
     ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/i},

    # --- Reddit -------------------------------------------------------------
    {:reddit, :pixel_id, ~r/rdt\s*\(\s*['"]init['"]\s*,\s*['"]([at]2_[a-z0-9]{4,})['"]/i},
    {:reddit, :pixel_id, ~r/\A([at]2_[a-z0-9]{4,})\z/i},

    # --- LinkedIn -----------------------------------------------------------
    # The partner id is not a credential this library uses, but it is the only
    # thing in LinkedIn's snippet, and recognising it lets the form say so
    # rather than leaving the paste box silent.
    {:linkedin, :partner_id, ~r/_linkedin_partner_id\s*=\s*['"](\d{4,12})['"]/},

    # --- Pinterest ----------------------------------------------------------
    {:pinterest, :tag_id, ~r/pintrk\s*\(\s*['"]load['"]\s*,\s*['"](\d{10,20})['"]/}
  ]

  @doc """
  Every credential recognisable in `text`, grouped by platform.

  Returns `%{}` for anything unrecognised — never raises, never guesses.
  """
  @spec detect(String.t() | nil) :: %{atom() => %{atom() => String.t()}}
  def detect(text) when is_binary(text) and byte_size(text) > 0 do
    # Bounded: a paste box is a text input, and a megabyte of it should cost
    # nothing. 20KB is far more than the largest platform snippet.
    text = binary_part(text, 0, min(byte_size(text), 20_000))

    Enum.reduce(@patterns, %{}, fn {platform, key, regex}, acc ->
      case Regex.run(regex, String.trim(text), capture: :all_but_first) do
        [value | _] -> put_new(acc, platform, key, value)
        _ -> acc
      end
    end)
  end

  def detect(_), do: %{}

  @doc """
  Pull `key` for `platform` out of `value`, which may be a bare id or a whole
  snippet.

  Falls through to the trimmed input when nothing matches: the person typing
  knows more about their account than a regex does, and a field that refuses
  what it does not recognise is a field that cannot be filled.
  """
  @spec clean(atom(), atom(), String.t() | nil) :: String.t()
  def clean(platform, key, value) when is_binary(value) do
    trimmed = String.trim(value)

    Enum.find_value(@patterns, trimmed, fn
      {^platform, ^key, regex} ->
        case Regex.run(regex, trimmed, capture: :all_but_first) do
          [found | _] -> found
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  def clean(_platform, _key, _value), do: ""

  @doc false
  @spec patterns() :: [{atom(), atom(), Regex.t()}]
  def patterns, do: @patterns

  defp put_new(acc, platform, key, value) do
    platform_creds = Map.get(acc, platform, %{})

    if Map.has_key?(platform_creds, key) do
      acc
    else
      Map.put(acc, platform, Map.put(platform_creds, key, value))
    end
  end
end
