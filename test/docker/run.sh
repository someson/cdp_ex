#!/usr/bin/env bash
# Builds the Ubuntu test image for one browser and runs leak_loop.sh in it.
#
#   test/docker/run.sh chromium            # native arch
#   test/docker/run.sh chrome              # linux/amd64 (emulated on Apple Silicon)
#   RUNS=50 TRACE=1 CPUS=4 test/docker/run.sh chromium
#
# CPUS caps the container's CPU share (0, the default, means no cap).
set -euo pipefail

browser="${1:-chromium}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
platform=()
erl_flags=()
if [ "$browser" = chrome ]; then
  platform=(--platform linux/amd64)
  # The BEAM JIT segfaults under amd64 emulation on Apple Silicon unless its
  # code is mapped single (one RWX mapping instead of two).
  [ "$(uname -m)" = arm64 ] && erl_flags=(-e "ERL_FLAGS=+JMsingle true")
fi

image="cdp_ex-test:$browser"
docker build "${platform[@]}" --build-arg BROWSER="$browser" -t "$image" "$root/test/docker"

docker run --rm "${platform[@]}" "${erl_flags[@]}" \
  --shm-size=1g \
  --cpus "${CPUS:-0}" \
  --cap-add SYS_PTRACE \
  -e RUNS -e TEST -e TRACE \
  -v "$root:/app" \
  -v "cdp_ex-deps-$browser:/app/deps" \
  -v "cdp_ex-build-$browser:/app/_build" \
  "$image"
