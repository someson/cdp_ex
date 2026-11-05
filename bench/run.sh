#!/usr/bin/env bash
# Runs the CDPEx and Playwright scenarios ROUNDS times against the fixture server
# and prints a Markdown table of medians. Run from anywhere; it works from the
# repository root. On Linux each run is also sampled for Chrome's memory and CPU.
#
#   bench/run.sh                         # all scenarios, both libraries
#   SCENARIOS="cold spa" LIBS=cdp_ex ROUNDS=5 bench/run.sh
#
# See bench/README.md for every variable.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

: "${CDP_EX_CHROME_BINARY:?set CDP_EX_CHROME_BINARY to the browser both libraries should drive}"
ROUNDS="${ROUNDS:-3}"
SCENARIOS="${SCENARIOS:-cold spa concurrent}"
LIBS="${LIBS:-cdp_ex playwright}"
out="${RESULTS:-bench/results/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"
results="$out/results.jsonl"

sample=0
[ -r /proc/self/smaps_rollup ] && sample=1

echo "browser: $("$CDP_EX_CHROME_BINARY" --version 2>/dev/null || echo unknown)"
echo "elixir:  $(elixir --version | tail -n1)"
echo "node:    $(node --version)"
quota=""
# A container's --cpus is a CFS quota, which getconf doesn't see.
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r max period </sys/fs/cgroup/cpu.max
  [ "$max" != max ] && quota=" (quota $((max / period)) CPUs)"
fi
echo "cpus:    $(getconf _NPROCESSORS_ONLN)$quota"
echo "results: $out"

MIX_ENV="${MIX_ENV:-dev}" mix compile >/dev/null

node bench/fixture/server.mjs >"$out/port" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -s "$out/port" ] && break; sleep 0.1; done
export BASE_URL="http://127.0.0.1:$(cat "$out/port")"

run_lib() {
  case "$1" in
    cdp_ex) MIX_ENV="${MIX_ENV:-dev}" mix run bench/cdp_ex.exs ;;
    playwright) node bench/playwright.mjs ;;
    *) echo "unknown library $1" >&2; return 2 ;;
  esac
}

for round in $(seq "$ROUNDS"); do
  for scenario in $SCENARIOS; do
    for lib in $LIBS; do
      echo "round $round: $scenario / $lib"
      tag="$out/$round-$scenario-$lib"
      sampler=""
      if [ "$sample" = 1 ]; then
        node bench/sampler.mjs "$CDP_EX_CHROME_BINARY" >"$tag.sample.json" &
        sampler=$!
      fi

      SCENARIO="$scenario" run_lib "$lib" >"$tag.json" 2>"$tag.log"

      if [ -n "$sampler" ]; then
        kill -TERM "$sampler"
        wait "$sampler" || true
      fi
      node bench/report.mjs add "$results" "$round" "$tag.json" "$tag.sample.json"
    done
  done
done

node bench/report.mjs table "$results" | tee "$out/table.md"
