defmodule Pixelex.SecretsTest do
  use ExUnit.Case, async: false

  alias Pixelex.Secrets

  @key Base.encode64(:crypto.strong_rand_bytes(32))

  setup do
    on_exit(fn ->
      Application.delete_env(:pixelex, :secret_key)
      :persistent_term.erase({Secrets, :undecryptable})
      :persistent_term.erase({Secrets, :bad_key})
    end)

    :ok
  end

  defp with_key(key), do: Application.put_env(:pixelex, :secret_key, key)

  test "without a key, values pass through untouched" do
    refute Secrets.enabled?()
    assert Secrets.encrypt("EAAtoken") == "EAAtoken"
    assert Secrets.decrypt("EAAtoken") == "EAAtoken"
  end

  test "round-trips under a key, and the ciphertext is not the plaintext" do
    with_key(@key)
    assert Secrets.enabled?()

    encrypted = Secrets.encrypt("EAAtoken")
    assert Secrets.encrypted?(encrypted)
    refute encrypted =~ "EAAtoken"
    assert Secrets.decrypt(encrypted) == "EAAtoken"
  end

  test "the nonce is fresh, so the same token encrypts differently each time" do
    with_key(@key)
    refute Secrets.encrypt("same") == Secrets.encrypt("same")
  end

  test "turning encryption on is not a migration: plaintext still reads" do
    with_key(@key)
    assert Secrets.decrypt("written-before-the-key-existed") == "written-before-the-key-existed"
  end

  test "already-encrypted values are not encrypted twice" do
    with_key(@key)
    once = Secrets.encrypt("token")
    assert Secrets.encrypt(once) == once
  end

  # The important one. Handing ciphertext to an ad platform means an
  # integration that reports itself configured and 401s forever.
  test "a rotated-away key yields nil, not ciphertext" do
    with_key(@key)
    encrypted = Secrets.encrypt("token")

    with_key(Base.encode64(:crypto.strong_rand_bytes(32)))
    assert Secrets.decrypt(encrypted) == nil

    Application.delete_env(:pixelex, :secret_key)
    assert Secrets.decrypt(encrypted) == nil
  end

  test "tampered ciphertext fails the GCM tag rather than decrypting" do
    with_key(@key)
    "pxenc1:" <> body = Secrets.encrypt("token")
    {:ok, raw} = Base.decode64(body)
    <<head::binary-30, byte, rest::binary>> = raw

    tampered = "pxenc1:" <> Base.encode64(head <> <<Bitwise.bxor(byte, 1)>> <> rest)
    assert Secrets.decrypt(tampered) == nil
  end

  test "raw 32 bytes work as well as base64" do
    with_key(:crypto.strong_rand_bytes(32))
    assert Secrets.decrypt(Secrets.encrypt("token")) == "token"
  end

  test "a key of the wrong length stores plaintext rather than pretending" do
    with_key("too-short")
    refute Secrets.enabled?()
    assert Secrets.encrypt("token") == "token"
  end
end
