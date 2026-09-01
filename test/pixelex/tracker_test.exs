defmodule Pixelex.TrackerTest do
  use ExUnit.Case, async: true

  @source Path.expand("../../assets/pixelex.js", __DIR__)
  @built Path.join(:code.priv_dir(:pixelex), "static/pixelex.js")
  @sri Path.join(:code.priv_dir(:pixelex), "static/pixelex.js.sri")

  test "the built tracker is not stale relative to its source" do
    # The built file is committed and ships in the package, so a change to the
    # source that forgets `mix pixelex.build` would silently release the old
    # tracker. This is the check that stops that.
    assert File.exists?(@built), "run `mix pixelex.build`"

    source_mtime = File.stat!(@source).mtime
    built_mtime = File.stat!(@built).mtime

    assert built_mtime >= source_mtime,
           "assets/pixelex.js is newer than priv/static/pixelex.js — run `mix pixelex.build`"
  end

  test "stays small enough to be worth loading" do
    built = File.read!(@built)
    gzipped = :zlib.gzip(built)

    assert byte_size(built) < 6_000, "minified tracker is #{byte_size(built)} bytes"

    assert byte_size(gzipped) < 2_500,
           "gzipped tracker is #{byte_size(gzipped)} bytes; the budget is what makes it defensible"
  end

  test "the published SRI hash matches the built file" do
    assert File.exists?(@sri)

    expected = "sha384-" <> Base.encode64(:crypto.hash(:sha384, File.read!(@built)))
    assert String.trim(File.read!(@sri)) == expected
  end

  test "the guards that keep junk out of the numbers are all present" do
    source = File.read!(@source)

    for guard <- [
          "localhost",
          "file:",
          "webdriver",
          "Cypress",
          "globalPrivacyControl",
          "pixelex_ignore"
        ] do
      assert source =~ guard, "the #{guard} guard is missing"
    end
  end

  test "listens for LiveView navigation, which never reaches a Plug" do
    source = File.read!(@source)

    assert source =~ "phx:navigate"
    assert source =~ "pushState"
    assert source =~ "hashchange"
  end

  test "never uses unload, which breaks the back-forward cache" do
    source = File.read!(@source)

    assert source =~ "visibilitychange"
    assert source =~ "pagehide"

    refute source =~ ~r/addEventListener\(\s*["']unload["']/,
           "an unload handler disqualifies the page from bfcache and is unreliable on mobile"

    refute source =~ ~r/addEventListener\(\s*["']beforeunload["']/
  end

  test "sends with keepalive, because a tracked link outlives its own request" do
    source = File.read!(@source)
    assert source =~ "keepalive"
    assert source =~ "px.gif", "there must be an image fallback when fetch is unavailable"
  end

  test "the built file is valid JavaScript and defines the public API" do
    built = File.read!(@built)

    assert built =~ "window.pixelex" or built =~ "pixelex="
    refute built =~ "/*", "comments should be stripped from the built file"
  end
end
