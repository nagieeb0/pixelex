defmodule Pixelex.Destinations.DeliveryTest do
  @moduledoc """
  The two faults that made conversions arrive unmatched, and the queue path
  never be taken. Both were invisible: the platforms answer `200`.
  """
  use ExUnit.Case, async: false

  alias Pixelex.Destinations

  @args %{
    "site_id" => "shop",
    "event" => "purchase",
    "event_id" => "order:1",
    "event_time" => 1_700_000_000,
    "event_source_url" => "https://shop.test/thanks",
    "action_source" => "website",
    "user_data" => %{
      "email" => "a@b.com",
      "phone" => "+201234567890",
      "ip" => "197.55.10.3",
      "user_agent" => "Mozilla/5.0",
      "fbclid" => "IwAR123",
      "external_id" => "cust-9"
    },
    "custom_data" => %{"currency" => "EGP", "value" => 1499.0, "content_ids" => ["sku-1"]}
  }

  describe "from_args/1 — the match keys have to survive the queue" do
    test "every user_data key the clients read comes back" do
      user_data = Destinations.from_args(@args)[:user_data]

      assert user_data[:email] == "a@b.com"
      assert user_data[:phone] == "+201234567890"
      assert user_data[:ip] == "197.55.10.3"
      assert user_data[:user_agent] == "Mozilla/5.0"
      assert user_data[:fbclid] == "IwAR123"
      assert user_data[:external_id] == "cust-9"
    end

    test "custom_data is passed through, string keys and all" do
      custom = Destinations.from_args(@args)[:custom_data]

      # Meta, TikTok, Snapchat and Pinterest forward the whole map, so nothing
      # here may be filtered by key.
      assert custom["currency"] == "EGP"
      assert custom["value"] == 1499.0
      assert custom["content_ids"] == ["sku-1"]
    end

    test "an arbitrary custom property is not dropped" do
      args = put_in(@args["custom_data"], %{"my_own_field" => "keep me"})
      assert Destinations.from_args(args)[:custom_data]["my_own_field"] == "keep me"
    end

    # The regression itself: user_data used to run through @credential_keys.
    test "a credential key smuggled into user_data is not carried" do
      args = put_in(@args["user_data"], %{"access_token" => "EAAnope", "email" => "a@b.com"})
      user_data = Destinations.from_args(args)[:user_data]

      assert user_data == %{email: "a@b.com"}
    end

    test "an unknown key is dropped rather than growing the atom table" do
      args = put_in(@args["user_data"], %{"definitely_not_an_atom_yet_9f2a" => "x"})

      assert Destinations.from_args(args)[:user_data] == %{}
    end

    test "the whole round trip reaches Meta with a populated user_data" do
      Application.put_env(:pixelex, :req_options, plug: {Req.Test, DeliveryStub})

      Application.put_env(:pixelex, :sites, %{
        "shop" => [
          destinations: %{
            "meta" => %{"pixel_id" => "1234567890123456", "access_token" => "EAAtoken"}
          }
        ]
      })

      on_exit(fn ->
        Application.delete_env(:pixelex, :req_options)
        Application.delete_env(:pixelex, :sites)
        Pixelex.Sites.reset()
      end)

      Pixelex.Sites.reset()
      parent = self()

      Req.Test.stub(DeliveryStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        Req.Test.json(conn, %{"events_received" => 1})
      end)

      assert [{:meta, :ok}] =
               Destinations.dispatch("shop", :purchase, Destinations.from_args(@args))

      assert_received {:body, body}
      assert [event] = body["data"]

      # Meta wants hashed match keys as arrays; an empty user_data is what it
      # rejects outright.
      assert %{"em" => [_], "ph" => [_], "external_id" => [_]} = event["user_data"]
      assert event["user_data"]["client_ip_address"] == "197.55.10.3"
      assert event["user_data"]["client_user_agent"] == "Mozilla/5.0"
      assert event["user_data"]["fbc"] =~ "IwAR123"
      assert event["custom_data"]["currency"] == "EGP"
    end
  end

  describe "oban_name/0" do
    test "defaults to Oban and is configurable" do
      assert Destinations.oban_name() == Oban

      Application.put_env(:pixelex, :oban_name, MyApp.Oban)
      on_exit(fn -> Application.delete_env(:pixelex, :oban_name) end)

      assert Destinations.oban_name() == MyApp.Oban
    end

    # Oban registers its supervisor through Oban.Registry, never the local
    # process registry, so the old `Process.whereis(Oban)` check answered nil
    # on a healthy Oban and every conversion took the task branch.
    test "Oban is not registered under its own name in the process registry" do
      assert Process.whereis(Oban) == nil
      assert function_exported?(Oban.Registry, :whereis, 2)
    end
  end
end
