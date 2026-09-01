defmodule Pixelex.IngestTest do
  # Not async: one named buffer process and one global ETS table.
  use ExUnit.Case, async: false

  alias Pixelex.{Event, Ingest, Store}
  alias Pixelex.Test.FlakyStore

  setup do
    # Order matters: drain whatever a previous test left buffered FIRST, then
    # clear the store. Resetting first lets the leftovers land in the next
    # test's store and read as its own writes.
    Application.put_env(:pixelex, :store, Store.ETS)
    Application.put_env(:pixelex, :max_buffer, 200)
    Application.put_env(:pixelex, :flush_bytes, 1_000_000)
    FlakyStore.reset()
    Ingest.flush()
    # Wait for in-flight async flushes too. Without this a write spawned by the
    # previous test lands after the reset below and reads as this test's own.
    settle()
    Store.ETS.reset()

    on_exit(fn ->
      Application.put_env(:pixelex, :store, Store.ETS)
      Application.put_env(:pixelex, :max_buffer, 200)
      Application.put_env(:pixelex, :flush_bytes, 1_000_000)
      FlakyStore.reset()
    end)

    :ok
  end

  defp event(name \\ "signup") do
    {:ok, e} = Event.new(%{site_id: "site", name: name})
    e
  end

  test "a pushed event reaches the store on the next flush" do
    Ingest.push(event("signup"))
    assert {:ok, 1} = Ingest.flush()

    assert [%Event{name: "signup"}] = Store.ETS.all()
  end

  test "the timer flushes without anyone asking" do
    Ingest.push(event())
    # flush_ms is 50 in test config.
    assert eventually(fn -> length(Store.ETS.all()) == 1 end)
  end

  test "crossing flush_bytes flushes before the timer would" do
    Application.put_env(:pixelex, :flush_bytes, 1)
    Ingest.push(event())

    assert eventually(fn -> length(Store.ETS.all()) == 1 end, 40)
  end

  test "a replayed batch does not duplicate rows" do
    e = event()
    Ingest.push(e)
    assert {:ok, 1} = Ingest.flush()

    Ingest.push(e)
    assert {:ok, 0} = Ingest.flush(), "second write of the same event_id must be a no-op"
    assert length(Store.ETS.all()) == 1
  end

  test "events past max_buffer are dropped, not queued" do
    :telemetry.attach(
      "drop-test",
      [:pixelex, :ingest, :drop],
      fn _e, m, meta, pid -> send(pid, {:drop, m.count, meta.reason}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("drop-test") end)

    # One cast, so the whole batch is judged in a single message and the timer
    # cannot interleave: 500 offered, 200 of room, 300 dropped.
    Ingest.push_all(for i <- 1..500, do: event("e#{i}"))

    assert_receive {:drop, 300, :buffer_full}, 1_000
    assert Ingest.pending() <= 200
  end

  test "a failed flush returns the batch to the buffer" do
    Application.put_env(:pixelex, :store, FlakyStore)
    FlakyStore.fail_next(1)

    Ingest.push(event("survives"))
    assert {:error, :store_unavailable} = Ingest.flush()

    assert Ingest.pending() == 1,
           "a failed synchronous flush must keep the batch, not silently discard it"

    # The synchronous path reports the error; the async path is what requeues,
    # so drive it the way production does and let the timer retry.
    Ingest.push(event("retried"))
    assert eventually(fn -> Enum.any?(Store.ETS.all(), &(&1.name == "retried")) end, 60)
  end

  test "terminate flushes what is buffered rather than dropping it" do
    # Push the periodic flush out of the way so terminate/2 is provably the
    # thing that writes, not the timer racing it. The buffer reschedules on
    # each tick, so one tick at the old interval installs the new one.
    Application.put_env(:pixelex, :flush_ms, 30_000)
    Process.sleep(80)

    Ingest.push(event("shutdown"))
    assert Ingest.pending() == 1

    # Restarting the buffer runs terminate/2, which must not lose the event.
    ref = Process.monitor(Process.whereis(Ingest))
    GenServer.stop(Ingest, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

    assert Enum.any?(Store.ETS.all(), &(&1.name == "shutdown")),
           "buffered events must survive a graceful shutdown"

    # Pixelex.Supervisor is one_for_one, so it brings the buffer back on its own
    # — but the replacement read flush_ms at init and inherited the 30s interval
    # this test installed. Restore the real one and bounce it again, or every
    # later test sits waiting half a minute for a tick.
    assert eventually(fn -> is_pid(Process.whereis(Ingest)) end)
    Application.put_env(:pixelex, :flush_ms, 50)
    bounce_buffer()
  end

  defp bounce_buffer do
    ref = Process.monitor(Process.whereis(Ingest))
    GenServer.stop(Ingest, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    assert eventually(fn -> is_pid(Process.whereis(Ingest)) end)
  end

  test "telemetry reports what was flushed" do
    :telemetry.attach(
      "flush-test",
      [:pixelex, :ingest, :flush],
      fn _e, m, _meta, pid -> send(pid, {:flush, m}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("flush-test") end)

    # Trip the byte threshold rather than waiting on the timer: a preceding test
    # can leave the buffer holding a long interval, and this test is about what
    # the flush reports, not about when it happens.
    Application.put_env(:pixelex, :flush_bytes, 1)
    Ingest.push_all([event("a"), event("b")])

    assert_receive {:flush, %{count: 2, written: 2, bytes: bytes, duration_us: us}}, 1_000
    assert bytes > 0
    assert us >= 0
  end

  defp settle do
    assert eventually(fn -> Ingest.stats() == %{pending: 0, inflight: 0} end, 50),
           "buffer did not quiesce: #{inspect(Ingest.stats())}"
  end

  defp eventually(fun, tries \\ 30) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(),
        do: {:halt, true},
        else:
          (
            Process.sleep(20)
            {:cont, false}
          )
    end)
  end
end
