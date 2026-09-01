defmodule Pixelex.IdentityTest do
  use ExUnit.Case, async: false

  alias Pixelex.{Config, Sessions}
  alias Pixelex.Identity
  alias Pixelex.Identity.Salts

  @ua "Mozilla/5.0 (Linux; Android 14) Chrome/120"
  @ip "197.55.10.3"

  setup do
    # :memory keeps the whole test off the database and lets the injected clock
    # drive rotation, which is exactly the behaviour under test.
    Application.put_env(:pixelex, :salt_persistence, :memory)
    set_day(~D[2026-09-01])
    Salts.refresh()
    Sessions.reset()

    on_exit(fn ->
      Application.delete_env(:pixelex, :clock)
      Application.put_env(:pixelex, :salt_persistence, :repo)
      Application.put_env(:pixelex, :session_timeout_ms, 30 * 60 * 1_000)
      Sessions.reset()
    end)

    :ok
  end

  defp set_day(date), do: Application.put_env(:pixelex, :clock, fn -> date end)

  defp advance_day(date) do
    set_day(date)
    Salts.refresh()
  end

  describe "hashing" do
    test "the same visitor hashes the same way twice" do
      a = Identity.visitor("site", @ua, @ip)
      b = Identity.visitor("site", @ua, @ip)
      assert a.id == b.id
    end

    test "a different IP, user agent or site is a different visitor" do
      base = Identity.visitor("site", @ua, @ip).id

      refute base == Identity.visitor("site", @ua, "197.55.10.4").id
      refute base == Identity.visitor("site", "curl/8", @ip).id
      refute base == Identity.visitor("other-site", @ua, @ip).id
    end

    test "field boundaries cannot be shifted to collide two visitors" do
      # Without a delimiter in the hashed payload these two are byte-identical
      # once concatenated, and two different people on two different sites
      # become one. This is the test that keeps the separator in.
      refute Identity.visitor("ab", "c", @ip).id == Identity.visitor("a", "bc", @ip).id
    end

    test "the id is short, url-safe and stable in length" do
      id = Identity.visitor("site", @ua, @ip).id
      assert String.length(id) == 11
      assert id =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "a nil user agent or IP still yields a usable id" do
      assert %{id: id} = Identity.visitor("site", nil, nil)
      assert is_binary(id)
    end
  end

  describe "salt rotation" do
    test "there is no previous salt on the first day" do
      assert %{previous: nil} = Salts.get()
      assert %{previous_id: nil} = Identity.visitor("site", @ua, @ip)
    end

    test "rotating the day changes the salt and yesterday's becomes previous" do
      %{current: day1} = Salts.get()

      advance_day(~D[2026-09-02])
      %{current: day2, previous: previous} = Salts.get()

      refute day1 == day2, "the salt must change at the day boundary"
      assert previous == day1, "yesterday's salt must still be reachable"
    end

    test "the same visitor is unlinkable across days" do
      before = Identity.visitor("site", @ua, @ip).id

      advance_day(~D[2026-09-02])
      after_rotation = Identity.visitor("site", @ua, @ip).id

      refute before == after_rotation,
             "a stable cross-day identifier would make this a tracking cookie in all but name"
    end

    test "visitor/3 reports yesterday's id alongside today's after a rotation" do
      yesterday_id = Identity.visitor("site", @ua, @ip).id

      advance_day(~D[2026-09-02])
      assert %{id: today_id, previous_id: ^yesterday_id} = Identity.visitor("site", @ua, @ip)
      refute today_id == yesterday_id
    end
  end

  describe "sessions" do
    test "a first event starts a session" do
      assert %{new_session?: true, event_index: 0, session_id: sid} =
               Sessions.resolve("site", @ua, @ip)

      assert is_binary(sid)
    end

    test "a second event continues it and counts up" do
      %{session_id: first} = Sessions.resolve("site", @ua, @ip)

      assert %{new_session?: false, event_index: 1, session_id: ^first} =
               Sessions.resolve("site", @ua, @ip)
    end

    test "a different visitor gets a different session" do
      %{session_id: a} = Sessions.resolve("site", @ua, @ip)
      %{session_id: b} = Sessions.resolve("site", "curl/8", @ip)
      refute a == b
    end

    test "inactivity past the timeout ends the session" do
      Application.put_env(:pixelex, :session_timeout_ms, 30)
      %{session_id: first} = Sessions.resolve("site", @ua, @ip)

      Process.sleep(50)

      assert %{new_session?: true, session_id: second} = Sessions.resolve("site", @ua, @ip)
      refute first == second
    end

    test "the sweeper deletes idle sessions and spares live ones" do
      Application.put_env(:pixelex, :session_timeout_ms, 30)
      Sessions.resolve("site", @ua, @ip)
      Process.sleep(50)

      Application.put_env(:pixelex, :session_timeout_ms, 30 * 60 * 1_000)
      Sessions.resolve("site", "fresh-agent", @ip)

      Application.put_env(:pixelex, :session_timeout_ms, 30)
      assert Sessions.sweep() == 1
      assert Sessions.active() == 1
    end
  end

  describe "the midnight handover" do
    test "an open session survives the salt rotation" do
      %{session_id: before, visitor_id: id_before} = Sessions.resolve("site", @ua, @ip)

      advance_day(~D[2026-09-02])

      resolution = Sessions.resolve("site", @ua, @ip)

      assert resolution.session_id == before,
             """
             The session ended at midnight. This is the failure the whole
             previous-salt mechanism exists to prevent: nothing raises, no log
             line appears, and the site's session count silently spikes every
             night while average duration collapses.
             """

      refute resolution.new_session?
      refute resolution.visitor_id == id_before, "the stored id must be today's, not yesterday's"
      assert resolution.event_index == 1, "the event counter continues rather than restarting"
    end

    test "the session is re-keyed to today's id, not duplicated" do
      Sessions.resolve("site", @ua, @ip)
      assert Sessions.active() == 1

      advance_day(~D[2026-09-02])
      Sessions.resolve("site", @ua, @ip)

      assert Sessions.active() == 1,
             "carrying the session across must move it, not leave yesterday's entry behind"
    end

    test "a session already idle past the timeout is not resurrected by the handover" do
      Application.put_env(:pixelex, :session_timeout_ms, 30)
      %{session_id: stale} = Sessions.resolve("site", @ua, @ip)
      Process.sleep(50)

      advance_day(~D[2026-09-02])

      assert %{new_session?: true, session_id: fresh} = Sessions.resolve("site", @ua, @ip)
      refute fresh == stale
    end

    test "two rotations later, yesterday's-yesterday cannot revive a session" do
      Sessions.resolve("site", @ua, @ip)

      advance_day(~D[2026-09-02])
      advance_day(~D[2026-09-03])

      assert %{new_session?: true} = Sessions.resolve("site", @ua, @ip),
             "only one day of grace is offered, by design"
    end
  end

  describe "page-view deduplication" do
    test "the first view of a path counts and an immediate repeat does not" do
      %{visitor_id: v} = Sessions.resolve("site", @ua, @ip)

      assert Sessions.first_view?(v, "/pricing")

      refute Sessions.first_view?(v, "/pricing"),
             "the connected render of the same page is not a second visit"
    end

    test "a different path is a different view" do
      %{visitor_id: v} = Sessions.resolve("site", @ua, @ip)

      assert Sessions.first_view?(v, "/pricing")
      assert Sessions.first_view?(v, "/about"), "live_patch to another page is a real view"
      assert Sessions.first_view?(v, "/pricing"), "and navigating back is another"
    end

    test "the same path again after the window is a real reload" do
      %{visitor_id: v} = Sessions.resolve("site", @ua, @ip)

      assert Sessions.first_view?(v, "/pricing", 20)
      refute Sessions.first_view?(v, "/pricing", 20)
      Process.sleep(40)
      assert Sessions.first_view?(v, "/pricing", 20)
    end

    test "two visitors do not deduplicate against each other" do
      %{visitor_id: a} = Sessions.resolve("site", @ua, @ip)
      %{visitor_id: b} = Sessions.resolve("site", @ua, "41.33.1.9")

      assert Sessions.first_view?(a, "/pricing")
      assert Sessions.first_view?(b, "/pricing")
    end

    test "an unknown visitor is always a first view" do
      assert Sessions.first_view?("never-seen", "/pricing")
    end

    test "deduplication survives the midnight handover" do
      %{visitor_id: v1} = Sessions.resolve("site", @ua, @ip)
      assert Sessions.first_view?(v1, "/pricing")

      advance_day(~D[2026-09-02])
      %{visitor_id: v2} = Sessions.resolve("site", @ua, @ip)

      refute v1 == v2

      refute Sessions.first_view?(v2, "/pricing"),
             "the session moved to the new id and brought its last page with it"
    end
  end

  describe "Config.today/0" do
    test "defaults to the real UTC date when no clock is injected" do
      Application.delete_env(:pixelex, :clock)
      assert Config.today() == Date.utc_today()
    end
  end
end
