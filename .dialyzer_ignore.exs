# Optional dependencies are resolved with `Code.ensure_loaded?/1` at compile
# time, so in any given build exactly one side of each branch is live and
# Dialyzer correctly reports the other as unreachable. Both sides matter — the
# `false` side is what runs for a consumer who installed neither ref_inspector
# nor ua_inspector — so the branches stay and these are silenced.
[
  {"lib/pixelex/attribution.ex", :pattern_match},
  {"lib/pixelex/enrich.ex", :pattern_match}
]
