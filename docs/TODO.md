# TODO

Open work found while benchmarking CDPEx against Playwright and fixing what
that turned up. Ordered by priority. Every number below comes from the same
benchmark setup unless noted: a 4 vCPU / 16 GB Linux container, Chromium build
1243 (Playwright's bundle) for both libraries, headless, a local fixture server,
3 rounds, medians.

## 1. Per-job isolation (browser contexts) — done

`isolated: true` on `new_page/2` and `with_page/3`, the default for
`Pool.with_page/3` (#12). Design and measurements:
`docs/design/2026-11-05-per-job-isolation.md`. Kept here so the item numbers
below stay stable.

## 2. Empty profile dir left by a launch cut short

**Problem.** The integration test "a real launch cut short by the capped
launch_timeout" (`with_page([], fun, deadline: 50)`) sometimes leaves an
empty `cdp_ex-*` dir in the temp dir: 7 of 20 runs on the code before #2 and
#3, 2 of 20 with them. No Chrome process is left; only the dir.

**Hypothesis (unconfirmed).** Chrome's child processes, started before the
browser process was killed, briefly outlive it and recreate the profile dir
after `remove_dir/1` has deleted it. `remove_dir/1` retries 5 times, 50 ms
apart, then gives up quietly.

**Not reproduced on current main** (2026-11-05, Apple Silicon host): 0 leftover
dirs and 0 Chrome processes in every run below.

| Setup | Runs |
|-------|------|
| macOS, Google Chrome stable | 20 |
| Ubuntu 26.04 container, Chrome for Testing 156 arm64 (Playwright 1.64.1), `strace` | 20 |
| Same, no `strace`, capped to 4 CPUs | 120 |
| Ubuntu 26.04 container, Google Chrome 157 amd64 (emulated), `strace` | 20 |

Under `strace`, the only `mkdir` of the profile dir came from the BEAM. The
harness is `test/docker/` (`TRACE=1` names the process that creates a leftover
dir). The container numbers still differ from the original setup (Chromium
1243 on a native 4 vCPU Linux host). Parked: rerun `TRACE=1
test/docker/run.sh` if a leftover dir shows up again. If one does leak, wait
for the whole Chrome process group to exit before removing the dir, or retry
removal for longer.

## 3. Pipe transport — done

`pipe: true` on `launch/1` (#13). Design and measurements:
`docs/design/2026-11-05-pipe-transport.md`. The measured cold-start gain is
small (about 15 ms on Linux, none on macOS); the stronger reason to use it is
that no DevTools TCP port is opened. The rest of the gap to Playwright is not in
the transport.

## 4. Default flags: what hasn't been measured

- `--disable-field-trial-config` (on by default since #1) was measured on
  Chromium only. Branded Google Chrome stable doesn't apply the field-trial
  testing config, so the flag should be close to a no-op there. Confirm.
- `--disable-component-extensions-with-background-pages` was the only other
  flag with a visible effect in the bisection (8 concurrent pages: 15.2 vs
  13.9 jobs/s, 27 vs 29 Chrome processes). Weak evidence; re-measure on top
  of `--disable-field-trial-config` before adding it.

## 5. Keep the benchmark reproducible — done

`bench/` (see `bench/README.md`): a Node fixture server, matching CDPEx and
Playwright scenarios (`cold`, `spa`, `concurrent`), a `/proc` sampler for
Chrome's PSS and CPU, and `bench/docker.sh` for the reference setup (Ubuntu
26.04 container, 4 CPUs, Playwright's Chromium for both libraries). The original
harness was not recovered, so this one is a rebuild: its absolute numbers differ
from the ones in `CHANGELOG.md` up to #13.

## 6. Upstream

Changes in this fork that `patrols/cdp_ex` doesn't have yet: the
`--disable-field-trial-config` default (#1), reaping Chrome when the VM exits
(#2), unique temp profile dirs (#3), in-page waits (#4), the README fixes
(#5), and sweeping stale temp profile dirs (#8). Upstream requires signed commits, so they need re-signing before being
offered there, and the PR numbers in `CHANGELOG.md` will differ.
