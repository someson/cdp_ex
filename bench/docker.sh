#!/usr/bin/env bash
# Builds the benchmark image and runs bench/run.sh in it, capped to CPUS CPUs
# (default 4, the setup the numbers in CHANGELOG.md come from). Variables for
# run.sh (ROUNDS, SCENARIOS, LIBS, ITERATIONS, ...) are passed through.
#
#   bench/docker.sh
#   CPUS=8 ROUNDS=5 SCENARIOS=concurrent bench/docker.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

docker build --build-arg BROWSER=chromium -t cdp_ex-test:chromium "$root/test/docker"
docker build -t cdp_ex-bench "$root/bench"

pass=()
for var in ROUNDS SCENARIOS LIBS ITERATIONS DURATION_S CONCURRENCY CDP_EX_LAUNCH_OPTS CDP_EX_PAGE_OPTS INTERVAL_MS; do
  [ -n "${!var:-}" ] && pass+=(-e "$var")
done

docker run --rm \
  --shm-size=1g \
  --cpus "${CPUS:-4}" \
  ${pass[@]+"${pass[@]}"} \
  -v "$root:/app" \
  -v cdp_ex-deps-chromium:/app/deps \
  -v cdp_ex-build-chromium:/app/_build \
  cdp_ex-bench
