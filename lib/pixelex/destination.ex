defmodule Pixelex.Destination do
  @moduledoc """
  Send one conversion to one ad platform.

  ## Why a library should do this at all

  A browser pixel misses every conversion an ad-blocker, Safari's ITP or a
  disabled-JavaScript client blocks — and conversions are the events ad spend
  is actually optimised against, so those are the expensive ones to lose.
  Mirroring them from the server fixes it, and the platforms all support the
  same trick to avoid double-counting: send the browser event and the server
  event with a **shared `event_id`**, and the platform keeps one.

  Nothing on Hex did this. Three applications in this workspace each wrote it
  separately, and each got a different subset right.

  ## The contract

  A destination is a module that knows four things: its name, how to say a
  canonical event in its own vocabulary, whether it has been given credentials,
  and how to make the call.

  Two rules matter more than the rest:

    * **`configured?/1` false means silence, not failure.** A tenant with a
      Meta pixel and no TikTok token should behave exactly as though TikTok did
      not exist. Every platform no-ops on missing credentials rather than
      logging, because "not set up" is the normal state for most platforms for
      most tenants.
    * **`event_name/1` returning `nil` means the platform has no equivalent.**
      Not every canonical event exists everywhere, and inventing a name to fill
      the gap creates an event the advertiser cannot use.

  ## Canonical events

  `:page_view` `:view_content` `:search` `:add_to_cart` `:initiate_checkout`
  `:add_payment_info` `:purchase` `:lead` `:complete_registration`
  `:subscribe` `:contact` `:schedule`

  These are the intersection of Meta's standard events, TikTok's, Snapchat's
  and GA4's recommended events. `Pixelex.Destinations.dialects/0` prints the
  whole mapping.

  ## Adding one

  Implement the four callbacks and add the module to
  `config :pixelex, destinations: [...]`. `Pixelex.Destinations.Hash` has the
  normalisation rules and `Pixelex.Destinations.HTTP` has the request, so a new
  platform is usually under a hundred lines.
  """

  @typedoc "Whatever a platform needs to authenticate; shape is the platform's business."
  @type credentials :: map()

  @typedoc """
  One conversion, with `user_data` still in the clear.

  Raw, not pre-hashed, and deliberately: Meta wants a phone number as digits
  while TikTok wants E.164 with the `+`, so a single shared digest cannot serve
  both. Hashing happens at the edge of each client.
  """
  @type conversion :: %{
          required(:event_id) => String.t(),
          required(:event_time) => integer(),
          optional(:event_source_url) => String.t() | nil,
          optional(:action_source) => String.t() | nil,
          optional(:user_data) => map(),
          optional(:custom_data) => map(),
          optional(:test_code) => String.t() | nil
        }

  @doc "A short atom identifying the platform: `:meta`, `:tiktok`, …"
  @callback name() :: atom()

  @doc "This platform's name for a canonical event, or `nil` if it has none."
  @callback event_name(canonical :: atom()) :: String.t() | nil

  @doc "Are there enough credentials to make a call? False means no-op, not error."
  @callback configured?(credentials()) :: boolean()

  @doc "Make the call. Return `{:error, _}` so the job retries; do not rescue."
  @callback deliver(credentials(), event_name :: String.t(), conversion()) ::
              :ok | {:error, term()}

  @doc """
  The user-data key holding this platform's click id, if it has one.

  `Pixelex.Attribution` captures `fbclid`, `ttclid` and the rest at the click;
  this is how each platform wants it named on the way back.
  """
  @callback click_id_key() :: atom() | nil

  @typedoc """
  One credential, described well enough for a settings screen to ask for it.

    * `:key` — the key in `t:credentials/0`
    * `:label` — what a marketer calls it, not what the API calls it
    * `:secret` — never rendered back to the browser, and encrypted at rest
      when `Pixelex.Secrets` has a key
    * `:hint` — **where in the platform's UI to find it.** The most valuable
      field here: every one of these lives four clicks deep in a different
      console.
    * `:type` — `:string` (default) or `:map` for `event=id` rules
    * `:optional` — a platform is `configured?/1` without it
  """
  @type field :: %{
          required(:key) => atom(),
          required(:label) => String.t(),
          optional(:secret) => boolean(),
          optional(:hint) => String.t(),
          optional(:placeholder) => String.t(),
          optional(:type) => :string | :map,
          optional(:optional) => boolean()
        }

  @doc """
  The credentials this platform needs, in the order a human should be asked.

  Implement it and `Pixelex.Dashboard.Settings` grows a card for the platform
  with no further work — including a custom destination in a host application.
  Omit it and the platform still works, it just cannot be configured from the
  dashboard.
  """
  @callback fields() :: [field()]

  @optional_callbacks click_id_key: 0, fields: 0
end
