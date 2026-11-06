#!/usr/bin/env bash
# Runs the competitor comparison (see bench/compare/README.md): the capability
# probes once per library, then ROUNDS rounds of every timed task, each
# (task, page, library) in a fresh container capped to CPUS CPUs. Whatever a
# library starts dies with its container; before every run the script checks
# that no run container is left.
#
#   bench/compare/run.sh
#   ROUNDS=1 ITERATIONS=3 DURATION_S=5 LIBS="cdp_ex wallaby" bench/compare/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image=cdp_ex-compare
net=cdp_ex-compare
label=cdp_ex-compare=run

ROUNDS="${ROUNDS:-3}"
CPUS="${CPUS:-4}"
LIBS="${LIBS:-cdp_ex playwright_ex chromic_pdf wallaby}"
TASKS="${TASKS:-screenshot:html screenshot:js screenshot:heavy pdf:html pdf:js pdf:heavy text:html text:js text:heavy click:js cold:html concurrent:html}"
PROBE="${PROBE:-1}"
stamp="$(date +%Y%m%d-%H%M%S)"
out="${RESULTS:-$root/bench/results/compare-$stamp}"
mkdir -p "$out"
results="$out/results.jsonl"
touch "$results"

docker build -q -t "$image" "$here" >/dev/null
docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null

volumes=(-v "$root:/app" -v cdp_ex-compare-deps:/app/bench/compare/deps -v cdp_ex-compare-build:/app/bench/compare/_build)

echo "compiling"
docker run --rm "${volumes[@]}" "$image" sh -c 'mix deps.get >/dev/null && mix compile >/dev/null' 

docker rm -f cdp_ex-compare-fixture >/dev/null 2>&1 || true
docker run -d --name cdp_ex-compare-fixture --network "$net" \
  --network-alias site.test --network-alias embed.test \
  --cpus 2 -e DELAY_MS="${DELAY_MS:-20}" \
  -v "$here/fixture:/fixture:ro" "$image" node /fixture/server.mjs >/dev/null
trap 'docker rm -f cdp_ex-compare-fixture >/dev/null 2>&1 || true' EXIT

versions="$(docker run --rm "$image" sh -c 'chromium --version; chromedriver --version | cut -d" " -f1-2; playwright --version; elixir --version | tail -n1; node --version')"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "host: $(uname -sm), docker $(docker info --format '{{.ServerVersion}}'), $CPUS CPUs per run"
  echo "$versions"
} | tee "$out/env.txt"

# Fails if a run container is still there: a library's leftovers must never
# share the machine with the next library's run.
check_clean() {
  local left
  left="$(docker ps -aq --filter "label=$label")"
  if [ -n "$left" ]; then
    echo "a run container is still present: $left" >&2
    exit 1
  fi
}

# run <tag> <env...> -- one container for one run
run() {
  local tag="$1"
  shift
  check_clean
  local envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm --label "$label" --network "$net" --cpus "$CPUS" --shm-size=1g \
    "${volumes[@]}" -e RESULTS_DIR=/out -v "$out:/out" \
    -e ITERATIONS -e DURATION_S -e CONCURRENCY -e INTERVAL_MS \
    ${envs[@]+"${envs[@]}"} \
    "$image" mix run --no-compile -e 'Compare.Bench.main()' >"$out/$tag.out" 2>"$out/$tag.log" || {
    echo "  failed, see $out/$tag.log" >&2
    check_clean
    return 0
  }
  check_clean
  # Only the result line: anything else a library prints stays in .out.
  grep '^{"' "$out/$tag.out" | tail -n1 >"$out/$tag.json" || true
  cat "$out/$tag.json" >>"$results"
}

if [ "$PROBE" = 1 ]; then
  for lib in $LIBS; do
    echo "probe: $lib"
    run "probe-$lib" "LIB=$lib" "TASK=probe"
  done
fi

# Firefox / WebKit, probed only: playwright_ex in the browsers image (Playwright's
# own builds), Wallaby through a Selenium Firefox container. Not timed.
selenium3_image="${SELENIUM3_IMAGE:-selenium/standalone-firefox@sha256:738eeec4eba6e44d0e5f0697e36b77b907e3c6fb647759a82fe47dec0d188abf}"
selenium_image="${SELENIUM_IMAGE:-selenium/standalone-firefox@sha256:e85b262cd5e07a7dbaf9f871a2476263ff24b4dc5d0969f58cb52d15d18dba07}"
if [ "$PROBE" = 1 ] && [ "${PROBE_BROWSERS:-1}" = 1 ]; then
  docker build -q -t "$image-browsers" -f "$here/Dockerfile.browsers" "$here" >/dev/null
  docker rm -f cdp_ex-compare-selenium >/dev/null 2>&1 || true
  docker run -d --name cdp_ex-compare-selenium --network "$net" --network-alias selenium \
    --shm-size=2g "$selenium_image" >/dev/null
  # Selenium 3 too (amd64 only, emulated on arm64): Wallaby speaks JSON Wire.
  docker rm -f cdp_ex-compare-selenium3 >/dev/null 2>&1 || true
  docker run -d --name cdp_ex-compare-selenium3 --network "$net" --network-alias selenium3 \
    --platform linux/amd64 --shm-size=2g "$selenium3_image" >/dev/null
  trap 'docker rm -f cdp_ex-compare-fixture cdp_ex-compare-selenium cdp_ex-compare-selenium3 >/dev/null 2>&1 || true' EXIT
  for host in selenium selenium3; do
    for _ in $(seq 90); do
      docker run --rm --network "$net" "$image" curl -fs "http://$host:4444/wd/hub/status" >/dev/null 2>&1 && break
      sleep 1
    done
  done
  echo "probe browsers: playwright_ex"
  image="$image-browsers" run "probe-browsers-playwright_ex" "LIB=playwright_ex" "TASK=probe_browsers"
  echo "probe browsers: wallaby"
  run "probe-browsers-wallaby" "LIB=wallaby" "TASK=probe_browsers" "SELENIUM_URL=http://selenium:4444/wd/hub/" "SELENIUM3_URL=http://selenium3:4444/wd/hub/"
  docker rm -f cdp_ex-compare-selenium cdp_ex-compare-selenium3 >/dev/null 2>&1 || true
fi

# The library order rotates each round so no library is always first or last.
read -r -a libs <<<"$LIBS"
for ((round = 1; round <= ROUNDS; round++)); do
  shift_by=$(( (round - 1) % ${#libs[@]} ))
  order=("${libs[@]:$shift_by}" "${libs[@]:0:$shift_by}")
  for tp in $TASKS; do
    task="${tp%%:*}"
    page="${tp##*:}"
    for lib in "${order[@]}"; do
      echo "round $round: $task/$page $lib"
      run "$round-$task-$page-$lib" "LIB=$lib" "TASK=$task" "PAGE=$page"
      # CDPEx also as "reuse": a page per worker, navigated by every job, as
      # ChromicPDF's session pool and a Wallaby session do.
      if [ "$lib" = cdp_ex ] && [ "$task" != cold ]; then
        echo "round $round: $task/$page cdp_ex (reuse)"
        run "$round-$task-$page-cdp_ex-reuse" "LIB=cdp_ex" "TASK=$task" "PAGE=$page" "CDP_EX_SETUP=reuse"
      fi
      if [ "$lib" = cdp_ex ] && [ "$task" = concurrent ]; then
        echo "round $round: $task/$page cdp_ex (pool)"
        run "$round-$task-$page-cdp_ex-pool" "LIB=cdp_ex" "TASK=$task" "PAGE=$page" "CDP_EX_SETUP=pool"
      fi
    done
  done
done

docker run --rm "${volumes[@]}" -v "$out:/out" "$image" \
  mix run --no-compile -e 'Compare.Report.main("/out")' | tee "$out/report.md"
