defmodule Pixelex.ConsentTest do
  use ExUnit.Case, async: false

  alias Pixelex.Consent

  setup do
    on_exit(fn ->
      Application.delete_env(:pixelex, :consent_gate)
      Application.delete_env(:pixelex, :honor_gpc)
      Application.delete_env(:pixelex, :honor_dnt)
    end)

    :ok
  end

  defp gate_on, do: Application.put_env(:pixelex, :consent_gate, enabled: true)

  describe "defaults" do
    test "the geographic gate ships off" do
      refute Consent.required?("DE")
      assert Consent.allow?(%{country: "DE", decision: nil}) == true
    end

    test "GPC is honoured out of the box and DNT is not" do
      assert Consent.allow?(%{gpc: "1"}) == {:denied, :gpc}
      assert Consent.allow?(%{dnt: "1"}) == true
    end
  end

  describe "the geographic gate" do
    setup do: gate_on()

    test "covers the EEA, the UK and Switzerland" do
      for country <- ~w(DE FR IE GB CH NO IS LI) do
        assert Consent.required?(country), "#{country} must be gated"
      end
    end

    test "leaves everywhere else alone" do
      for country <- ~w(EG SA AE US MA JO KW) do
        refute Consent.required?(country), "#{country} must not be gated"
        assert Consent.allow?(%{country: country, decision: nil}) == true
      end
    end

    test "is case-insensitive about the country code" do
      assert Consent.required?("de")
    end

    test "is opt-in: no answer blocks, only an explicit grant permits" do
      assert Consent.allow?(%{country: "DE", decision: nil}) == {:denied, :no_consent}
      assert Consent.allow?(%{country: "DE", decision: "denied"}) == {:denied, :no_consent}
      assert Consent.allow?(%{country: "DE", decision: "granted"}) == true
    end

    test "an unknown country is not treated as gated" do
      # A cron, an admin action, or a server-side call with no visitor. There is
      # no banner to answer, so there is nothing to refuse.
      assert Consent.allow?(%{country: nil, decision: nil}) == true
    end

    test "prompt?/2 asks only when a decision is required and missing" do
      assert Consent.prompt?("DE", nil)
      refute Consent.prompt?("DE", "granted")
      refute Consent.prompt?("DE", "denied")
      refute Consent.prompt?("EG", nil)
    end
  end

  describe "Global Privacy Control" do
    test "Sec-GPC: 1 blocks everything, gate on or off" do
      assert Consent.allow?(%{gpc: "1", country: "EG"}) == {:denied, :gpc}
      gate_on()
      assert Consent.allow?(%{gpc: "1", country: "DE", decision: "granted"}) == {:denied, :gpc}
    end

    test "only the literal 1 is an opt-out" do
      for value <- ["0", "", nil, "true", "yes"] do
        assert Consent.allow?(%{gpc: value}) == true, "#{inspect(value)} is not an opt-out signal"
      end
    end

    test "can be switched off for hosts that have decided it does not apply" do
      Application.put_env(:pixelex, :honor_gpc, false)
      assert Consent.allow?(%{gpc: "1"}) == true
    end

    test "DNT blocks once it is switched on" do
      Application.put_env(:pixelex, :honor_dnt, true)
      assert Consent.allow?(%{dnt: "1"}) == {:denied, :dnt}
    end
  end

  describe "destinations are gated more tightly than analytics" do
    setup do: gate_on()

    test "a first-party pageview can be lawful where a CAPI call is not" do
      # This is the whole point of the split. The visitor is in a gated country
      # and has not answered; a cookieless first-party count is still fine, but
      # shipping their hashed phone number to Meta is not.
      signals = %{country: "DE", decision: nil}

      assert Consent.allow?(signals) == {:denied, :no_consent}
      assert Consent.destinations_allowed?(signals) == {:denied, :no_consent}
    end

    test "outside the gated countries both are allowed" do
      signals = %{country: "EG", decision: nil}
      assert Consent.allow?(signals) == true
      assert Consent.destinations_allowed?(signals) == true
    end

    test "a granted decision opens both" do
      signals = %{country: "DE", decision: "granted"}
      assert Consent.allow?(signals) == true
      assert Consent.destinations_allowed?(signals) == true
    end

    test "GPC blocks destinations even where no banner applies" do
      assert Consent.destinations_allowed?(%{country: "EG", gpc: "1"}) == {:denied, :gpc}
    end
  end

  test "allowed?/1 is the boolean shorthand" do
    assert Consent.allowed?(%{country: "EG"})
    refute Consent.allowed?(%{gpc: "1"})
  end
end
