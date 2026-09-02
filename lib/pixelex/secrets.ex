defmodule Pixelex.Secrets do
  @moduledoc """
  Encryption at rest for the credentials a tenant pastes into the settings
  screen. Off unless you give it a key.

      config :pixelex, secret_key: System.get_env("PIXELEX_SECRET_KEY")

  Generate one with:

      :crypto.strong_rand_bytes(32) |> Base.encode64()

  ## Why this exists now and did not before

  While credentials only arrived from `config :pixelex, sites:`, they lived
  wherever the host already kept secrets and pixelex never owned them.
  `Pixelex.Dashboard.Settings` changes that: it invites a tenant to paste a
  long-lived ad-platform access token into a column pixelex writes. Owning the
  write path means owning what the column looks like in a `pg_dump`.

  ## AES-256-GCM, and the prefix

  Ciphertext is stored as `pxenc1:<base64(iv <> tag <> ciphertext)>`. The
  prefix is what makes turning encryption *on* a no-op migration: a plaintext
  value has no prefix, `decrypt/1` returns it unchanged, and it becomes
  ciphertext the next time it is saved. There is no flag day.

  The prefix is also the AAD, so a value cannot be moved between schemes.

  ## A wrong key returns `nil`, not garbage

  If the key is missing or rotated away, `decrypt/1` yields `nil` rather than
  the ciphertext. `configured?/1` then reads false and the destination goes
  quiet, which is the same behaviour as "not set up" — the platform's normal
  state. Handing the ciphertext to Meta instead would mean an authenticated
  integration that 401s forever while reporting itself as configured.
  """
  require Logger

  @prefix "pxenc1:"

  @doc "True when a key is configured and values will actually be encrypted."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(key())

  @doc "Encrypt a value. Without a key, returns it unchanged."
  @spec encrypt(String.t() | nil) :: String.t() | nil
  def encrypt(nil), do: nil
  def encrypt(""), do: ""
  def encrypt(@prefix <> _ = already), do: already

  def encrypt(value) when is_binary(value) do
    case key() do
      nil ->
        value

      key ->
        iv = :crypto.strong_rand_bytes(12)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @prefix, true)

        @prefix <> Base.encode64(iv <> tag <> ciphertext)
    end
  end

  @doc "Decrypt a value. Plaintext passes through; an undecryptable value is `nil`."
  @spec decrypt(String.t() | nil) :: String.t() | nil
  def decrypt(@prefix <> encoded) do
    with k when is_binary(k) <- key(),
         {:ok, <<iv::binary-12, tag::binary-16, ciphertext::binary>>} <- Base.decode64(encoded),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, k, iv, ciphertext, @prefix, tag, false) do
      plain
    else
      _ ->
        warn_undecryptable()
        nil
    end
  end

  def decrypt(value), do: value

  @doc "Is this value stored encrypted?"
  @spec encrypted?(term()) :: boolean()
  def encrypted?(@prefix <> _), do: true
  def encrypted?(_), do: false

  # 32 raw bytes, or base64 of them — a key pasted out of `Base.encode64/1`
  # and a key read from a binary env var should both just work.
  defp key do
    case Application.get_env(:pixelex, :secret_key) do
      <<key::binary-32>> ->
        key

      encoded when is_binary(encoded) and encoded != "" ->
        case Base.decode64(encoded) do
          {:ok, <<key::binary-32>>} -> key
          _ -> warn_bad_key()
        end

      _ ->
        nil
    end
  end

  defp warn_bad_key do
    warn_once(:bad_key, """
    [pixelex] `config :pixelex, secret_key:` is not a 32-byte key.

    Give it 32 raw bytes or their base64. Credentials are being stored in
    plaintext until it is. Generate one with:

        :crypto.strong_rand_bytes(32) |> Base.encode64()
    """)

    nil
  end

  defp warn_undecryptable do
    warn_once(:undecryptable, """
    [pixelex] could not decrypt a stored credential.

    The `:secret_key` is missing or has changed. Affected destinations will
    behave as though they were never configured. Re-enter the credential in the
    settings screen, or restore the previous key.
    """)
  end

  defp warn_once(tag, message) do
    unless :persistent_term.get({__MODULE__, tag}, false) do
      :persistent_term.put({__MODULE__, tag}, true)
      Logger.warning(message)
    end

    :ok
  end
end
