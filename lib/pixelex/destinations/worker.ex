if Code.ensure_loaded?(Oban) do
  defmodule Pixelex.Destinations.Worker do
    @moduledoc """
    Delivers one conversion to every platform a site has configured.

    ## Why this is a job and not a task

    Every version of this code that came before it used
    `Task.Supervisor.start_child/2`: an unlinked, unmonitored, in-memory task. A
    deploy, a node restart or a crash between the call returning and the HTTP
    round-trip completing dropped the event with no record that it had ever
    existed. No retry beyond `Req`'s in-request one, and the only trace was a
    log line — so the failure mode was silent under-reporting of exactly the
    conversions ad spend is optimised against.

    The prerequisite for making it retryable was already satisfied: every event
    carries a deterministic `event_id` derived from the row it describes, and
    every platform deduplicates on it. A replayed event cannot double-count.

    `max_attempts: 5` with Oban's default backoff spans roughly a minute to an
    hour — long enough to ride out a platform outage, short enough that the
    conversion still lands inside the attribution window.

    ## PII in job args

    `user_data` carries the raw email and phone that the platform clients hash
    before egress, so it sits in `oban_jobs.args` until the Pruner reaps it.
    This is the same personal data already stored in the host's own tables, so
    it is not a new category of exposure — but it IS a second place to scrub for
    a deletion request.

    ponytail: raw PII in args, bounded by the Pruner. Pre-hashing at enqueue
    would remove it, but Meta and Snapchat strip a phone number to digits while
    TikTok keeps the `+`, so one shared hash cannot serve all of them. Revisit
    if a deletion SLA needs `oban_jobs` covered.
    """
    use Oban.Worker, queue: :pixelex, max_attempts: 5

    alias Pixelex.Destinations

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"site_id" => site_id, "event" => event} = args}) do
      case canonical(event) do
        nil ->
          # Cannot succeed on a retry. Discard rather than burn five attempts.
          {:cancel, {:unknown_event, event}}

        canonical ->
          results = Destinations.dispatch(site_id, canonical, Destinations.from_args(args))

          case Enum.filter(results, &match?({_platform, {:error, _}}, &1)) do
            [] ->
              :ok

            failures ->
              # Fail the job so Oban retries. Partial success is fine to replay:
              # the platforms that already accepted this event_id deduplicate
              # the second copy.
              {:error, {:delivery_failed, failures}}
          end
      end
    end

    # Never String.to_atom on queue data — a malformed or tampered job would
    # grow the atom table without bound, and the atom table is never collected.
    defp canonical(name) do
      Enum.find(Destinations.canonical_events(), &(Atom.to_string(&1) == name))
    end
  end
end
