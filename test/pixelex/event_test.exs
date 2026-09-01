defmodule Pixelex.EventTest do
  use ExUnit.Case, async: true

  alias Pixelex.Event

  describe "uuid7/0" do
    test "is a v7 UUID with the RFC 9562 variant bits" do
      id = Event.uuid7()
      assert String.length(id) == 36
      assert String.at(id, 14) == "7"
      assert String.at(id, 19) in ~w(8 9 a b)
    end

    test "sorts by creation time across milliseconds" do
      ids =
        for _ <- 1..25 do
          Process.sleep(2)
          Event.uuid7()
        end

      assert ids == Enum.sort(ids), "UUIDv7 must be time-ordered; index locality depends on it"
    end

    test "does not collide within a single millisecond" do
      ids = for _ <- 1..5_000, do: Event.uuid7()
      assert length(Enum.uniq(ids)) == 5_000
    end

    test "encodes the current time in the leading 48 bits" do
      <<ms::big-unsigned-48, _::binary>> =
        Event.uuid7() |> String.replace("-", "") |> Base.decode16!(case: :lower)

      assert_in_delta ms, System.system_time(:millisecond), 5_000
    end
  end

  describe "new/1 validation" do
    test "accepts a minimal event and fills id, timestamp and version" do
      assert {:ok, event} = Event.new(%{site_id: "site", name: "signup"})
      assert event.id
      assert %DateTime{} = event.timestamp
      assert event.v == Event.schema_version()
      assert event.props == %{}
    end

    test "rejects a missing or empty site_id" do
      assert {:error, :invalid_site_id} = Event.new(%{name: "x"})
      assert {:error, :invalid_site_id} = Event.new(%{site_id: "", name: "x"})
      assert {:error, :invalid_site_id} = Event.new(%{site_id: 42, name: "x"})
    end

    test "rejects a blank name and trims a padded one" do
      assert {:error, :invalid_name} = Event.new(%{site_id: "s", name: "   "})
      assert {:error, :invalid_name} = Event.new(%{site_id: "s", name: nil})
      assert {:ok, %{name: "signup"}} = Event.new(%{site_id: "s", name: "  signup  "})
    end

    test "caps the name at 120 characters" do
      assert {:ok, _} = Event.new(%{site_id: "s", name: String.duplicate("x", 120)})

      assert {:error, :name_too_long} =
               Event.new(%{site_id: "s", name: String.duplicate("x", 121)})
    end

    test "accepts an atom name" do
      assert {:ok, %{name: "page_view"}} = Event.new(%{site_id: "s", name: :page_view})
    end
  end

  describe "new/1 hostile input" do
    test "truncates url and referrer to 2000 bytes" do
      {:ok, event} =
        Event.new(%{
          site_id: "s",
          name: "x",
          url: String.duplicate("u", 50_000),
          referrer: String.duplicate("r", 50_000)
        })

      assert byte_size(event.url) == 2_000
      assert byte_size(event.referrer) == 2_000
    end

    test "caps props at 50 keys and 500 bytes per string value" do
      props = for i <- 1..500, into: %{}, do: {"k#{i}", String.duplicate("v", 5_000)}
      {:ok, event} = Event.new(%{site_id: "s", name: "x", props: props})

      assert map_size(event.props) == 50
      assert Enum.all?(Map.values(event.props), &(byte_size(&1) == 500))
    end

    test "drops nil props and stringifies keys" do
      {:ok, event} = Event.new(%{site_id: "s", name: "x", props: %{"c" => true, a: 1, b: nil}})
      assert event.props == %{"a" => 1, "c" => true}
    end

    test "ignores unknown string keys without interning them as atoms" do
      # Asserting on :erlang.system_info(:atom_count) looks equivalent but is a
      # VM-global counter that async tests and lazy module loading also move.
      # Ask the precise question instead: did THIS key become an atom?
      keys = for i <- 1..200, do: "pixelex_junk_key_#{i}_#{System.unique_integer([:positive])}"

      for key <- keys do
        assert {:ok, _} = Event.new(%{"site_id" => "s", "name" => "x", key => "v"})
      end

      for key <- keys do
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end
    end

    test "rejects an unknown render tag rather than storing it" do
      {:ok, event} = Event.new(%{site_id: "s", name: "x", render: :nonsense})
      assert event.render == nil

      {:ok, event} = Event.new(%{site_id: "s", name: "x", render: :connected})
      assert event.render == :connected
    end
  end

  describe "skew_corrected/2" do
    test "recovers real client time when the browser clock is two hours fast" do
      now = DateTime.utc_now()
      client_ts = DateTime.add(now, 7_200, :second)
      sent_at = DateTime.add(client_ts, 3, :second)

      {:ok, event} = Event.new(%{site_id: "s", name: "x", timestamp: now, client_ts: client_ts})

      # The event was created 3s before it was sent, both read from the same
      # wrong clock, so the corrected time is 3s before the server received it.
      assert DateTime.diff(Event.skew_corrected(event, sent_at), now) == -3
    end

    test "falls back to the server timestamp when the client sent nothing" do
      {:ok, event} = Event.new(%{site_id: "s", name: "x"})
      assert Event.skew_corrected(event, DateTime.utc_now()) == event.timestamp
      assert Event.skew_corrected(event, nil) == event.timestamp
    end
  end
end
