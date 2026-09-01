defmodule Mix.Tasks.Pixelex.Build do
  @moduledoc """
  Minify `assets/pixelex.js` into `priv/static/pixelex.js` and write its SRI hash.

      mix pixelex.build

  Only maintainers need this; the built file is committed and ships in the
  package. `mix test` fails if the two drift apart, so a change to the source
  that forgets this step cannot be released.

  Needs `esbuild` on PATH, or `ESBUILD` pointing at one. Phoenix apps already
  have a copy at `~/.cache/phx-esbuild/package/bin/esbuild`.
  """
  @shortdoc "Rebuild the JavaScript tracker"
  use Mix.Task

  @source "assets/pixelex.js"
  @output "priv/static/pixelex.js"

  @impl Mix.Task
  def run(_args) do
    esbuild = find_esbuild!()

    {output, status} =
      System.cmd(esbuild, [
        @source,
        "--minify",
        "--target=es2017",
        "--legal-comments=none",
        "--outfile=#{@output}"
      ])

    if status != 0, do: Mix.raise("esbuild failed:\n#{output}")

    minified = File.read!(@output)
    sri = "sha384-" <> (:crypto.hash(:sha384, minified) |> Base.encode64())
    File.write!(@output <> ".sri", sri <> "\n")

    gzipped = :zlib.gzip(minified)

    Mix.shell().info("""
    #{@output}
      minified  #{byte_size(minified)} bytes
      gzipped   #{byte_size(gzipped)} bytes
      sri       #{sri}
    """)
  end

  defp find_esbuild! do
    candidates =
      [System.get_env("ESBUILD"), System.find_executable("esbuild")] ++
        [Path.expand("~/.cache/phx-esbuild/package/bin/esbuild")]

    Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) ||
      Mix.raise("esbuild not found. Install it, or set ESBUILD=/path/to/esbuild")
  end
end
