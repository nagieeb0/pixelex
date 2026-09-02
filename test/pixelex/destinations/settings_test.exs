defmodule Pixelex.Destinations.SettingsTest do
  @moduledoc """
  The write path behind the settings screen: what a Save button does.
  """
  use ExUnit.Case, async: false

  alias Pixelex.{Destinations, Secrets, Sites}

  @site "settings-test"
  @key Base.encode64(:crypto.strong_rand_bytes(32))

  setup do
    reset_site()

    on_exit(fn ->
      Application.delete_env(:pixelex, :sites)
      Application.delete_env(:pixelex, :secret_key)
      Application.delete_env(:pixelex, :req_options)
      :persistent_term.erase({Secrets, :undecryptable})
      reset_site()
    end)

    :ok
  end

  # No Ecto sandbox in this suite, so the row outlives the test and
  # `put_credentials/3` would merge into what the last one left.
  defp reset_site do
    Sites.reset()
    Sites.update(@site, %{destinations: %{}})
    Sites.reset()
  rescue
    _ -> Sites.reset()
  end

  describe "fields/1" do
    test "every built-in destination can be configured from a form" do
      for module <- Destinations.modules() do
        fields = Destinations.fields(module.name())
        assert fields != [], "#{inspect(module)} has no fields/0"

        for field <- fields do
          assert is_atom(field.key)
          assert is_binary(field.label)
        end
      end
    end

    test "the keys a form offers are keys the platform actually reads" do
      # A field named something configured?/1 never looks at is a form that
      # cannot be completed, and it fails as "not set up" with every box full.
      creds =
        for %{key: key} = field <- Destinations.fields(:meta),
            field[:optional] != true,
            into: %{},
            do: {key, "x"}

      assert Pixelex.Destinations.Meta.configured?(creds)
    end

    test "an unknown platform has no form" do
      assert Destinations.fields(:myspace) == []
    end
  end

  describe "put_credentials/3" do
    @tag :integration
    test "saves a pasted snippet as the id inside it" do
      assert {:ok, _} =
               Destinations.put_credentials(@site, :meta, %{
                 "pixel_id" => "<script>fbq('init', '1234567890123456');</script>",
                 "access_token" => "EAAtoken"
               })

      assert %{pixel_id: "1234567890123456", access_token: "EAAtoken"} =
               Destinations.credentials(@site)[:meta]
    end

    @tag :integration
    test "a blank secret keeps the stored one" do
      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken"
        })

      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "6543210987654321",
          "access_token" => ""
        })

      assert %{pixel_id: "6543210987654321", access_token: "EAAtoken"} =
               Destinations.credentials(@site)[:meta]
    end

    @tag :integration
    test "a blank non-secret clears it — the box carries the intent" do
      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken",
          "test_event_code" => "TEST123"
        })

      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "test_event_code" => ""
        })

      refute Map.has_key?(Destinations.credentials(@site)[:meta], :test_event_code)
    end

    @tag :integration
    test "other platforms on the site are untouched" do
      {:ok, _} =
        Destinations.put_credentials(@site, :ga4, %{
          "measurement_id" => "G-ABC1234XYZ",
          "api_secret" => "s3cret"
        })

      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken"
        })

      credentials = Destinations.credentials(@site)
      assert credentials[:ga4].measurement_id == "G-ABC1234XYZ"
      assert credentials[:meta].pixel_id == "1234567890123456"
    end

    @tag :integration
    test "LinkedIn's conversion rules parse out of a textarea" do
      {:ok, _} =
        Destinations.put_credentials(@site, :linkedin, %{
          "access_token" => "tok",
          "conversions" => "purchase=12345678\n lead = 87654321 \n\ngarbage"
        })

      assert Destinations.credentials(@site)[:linkedin].conversions ==
               %{"purchase" => "12345678", "lead" => "87654321"}
    end

    @tag :integration
    test "secrets are encrypted at rest and come back decrypted" do
      Application.put_env(:pixelex, :secret_key, @key)

      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken"
        })

      Sites.reset()
      stored = Sites.get(@site).destinations["meta"]

      assert Secrets.encrypted?(stored["access_token"])
      refute stored["access_token"] =~ "EAAtoken"
      # The pixel id is not a secret and stays legible in the column.
      assert stored["pixel_id"] == "1234567890123456"

      assert Destinations.credentials(@site)[:meta].access_token == "EAAtoken"
    end

    @tag :integration
    test "an undecryptable secret reads as not-set-up rather than as ciphertext" do
      Application.put_env(:pixelex, :secret_key, @key)

      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken"
        })

      Application.put_env(:pixelex, :secret_key, Base.encode64(:crypto.strong_rand_bytes(32)))
      Sites.reset()

      credentials = Destinations.credentials(@site)[:meta]
      refute Map.has_key?(credentials, :access_token)
      refute Pixelex.Destinations.Meta.configured?(credentials)
    end

    @tag :integration
    test "delete_credentials/2 forgets one platform and leaves the rest" do
      {:ok, _} =
        Destinations.put_credentials(@site, :meta, %{
          "pixel_id" => "1234567890123456",
          "access_token" => "EAAtoken"
        })

      {:ok, _} =
        Destinations.put_credentials(@site, :ga4, %{
          "measurement_id" => "G-ABC1234XYZ",
          "api_secret" => "s3cret"
        })

      {:ok, _} = Destinations.delete_credentials(@site, :meta)

      credentials = Destinations.credentials(@site)
      refute Map.has_key?(credentials, :meta)
      assert credentials[:ga4].measurement_id == "G-ABC1234XYZ"
    end

    test "refuses a config-defined site instead of saving into a void" do
      Application.put_env(:pixelex, :sites, %{@site => [domain: "x.test"]})

      assert {:error, :config_defined} =
               Destinations.put_credentials(@site, :meta, %{"pixel_id" => "1"})

      assert {:error, :config_defined} = Destinations.delete_credentials(@site, :meta)
    end

    test "refuses a platform it does not have" do
      assert {:error, :unknown_platform} =
               Destinations.put_credentials(@site, :myspace, %{"pixel_id" => "1"})
    end
  end

  describe "test/2" do
    test "reports not_configured rather than making a call" do
      Application.put_env(:pixelex, :sites, %{@site => [domain: "x.test"]})
      assert Destinations.test(@site, :meta) == {:error, :not_configured}
    end

    test "unknown platform" do
      assert Destinations.test(@site, :myspace) == {:error, :unknown_platform}
    end

    test "sends a real page_view and reports what came back" do
      Application.put_env(:pixelex, :req_options, plug: {Req.Test, SettingsStub})

      Application.put_env(:pixelex, :sites, %{
        @site => [
          domain: "shop.test",
          destinations: %{
            "meta" => %{"pixel_id" => "1234567890123456", "access_token" => "EAAtoken"}
          }
        ]
      })

      parent = self()

      Req.Test.stub(SettingsStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request, Jason.decode!(raw)})
        Req.Test.json(conn, %{"events_received" => 1})
      end)

      assert Destinations.test(@site, :meta) == :ok

      assert_received {:request, body}
      assert [%{"event_name" => "PageView", "event_id" => event_id} = event] = body["data"]
      assert String.starts_with?(event_id, "pixelex-test-")
      assert event["event_source_url"] == "https://shop.test"
    end

    test "a fresh event_id every time, so the second test is not deduplicated away" do
      Application.put_env(:pixelex, :req_options, plug: {Req.Test, SettingsStub})

      Application.put_env(:pixelex, :sites, %{
        @site => [
          destinations: %{
            "meta" => %{"pixel_id" => "1234567890123456", "access_token" => "EAAtoken"}
          }
        ]
      })

      parent = self()

      Req.Test.stub(SettingsStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:id, hd(Jason.decode!(raw)["data"])["event_id"]})
        Req.Test.json(conn, %{})
      end)

      assert Destinations.test(@site, :meta) == :ok
      assert Destinations.test(@site, :meta) == :ok

      assert_received {:id, first}
      assert_received {:id, second}
      refute first == second
    end

    test "a rejection is returned, not swallowed" do
      Application.put_env(:pixelex, :req_options, plug: {Req.Test, SettingsStub})

      Application.put_env(:pixelex, :sites, %{
        @site => [
          destinations: %{
            "meta" => %{"pixel_id" => "1234567890123456", "access_token" => "bad"}
          }
        ]
      })

      Req.Test.stub(SettingsStub, fn conn ->
        Req.Test.json(%{conn | status: 400}, %{"error" => %{"message" => "Invalid OAuth token"}})
      end)

      assert {:error, {:meta, 400, _}} = Destinations.test(@site, :meta)
    end
  end
end
