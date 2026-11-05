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

## 4. Default flags — done

Both measured (2026-11-05); the second is now a default (#15).

- `--disable-field-trial-config` is a no-op on branded Google Chrome, as
  expected. Read from `chrome://version/?show-variations-cmd` with and without
  the flag (2026-11-05):

  | Browser | Forced field-trial tokens, with / without | Enabled features, with / without |
  |---------|------------------|------------------|
  | Google Chrome 156, macOS arm64 | 4 / 4 | 1 / 1 |
  | Google Chrome 157, Linux amd64 (`test/docker` `chrome`) | 4 / 4 | 1 / 1 |
  | Chrome for Testing 156, Linux arm64 (`test/docker` `chromium`) | 2 / 1131 | 1 / 632 |

  Keep it: it only changes builds that apply the testing config.
- `--disable-component-extensions-with-background-pages`, re-measured on top of
  `--disable-field-trial-config` with `bench/docker.sh` (Chrome for Testing 156,
  4 CPUs), 5 alternating pairs of runs, medians:

  | Scenario | Without | With |
  |----------|---------|------|
  | `cold` p50 | 255 ms, 376 MB, 11 procs | 247 ms, 363 MB, 10 procs |
  | `concurrent` | 23.9 jobs/s, 500 MB, 17 procs | 24.5 jobs/s, 501 MB, 16 procs |

  One Chrome process fewer at every cold start (and at peak in 4 of 5 loaded
  runs), and about 13 MB less at cold start.
  Throughput and peak memory under load are within run-to-run noise (22.4–25.2
  vs 23.0–25.7 jobs/s). Playwright passes it by default (playwright-core 1.64.1).
  Added as a default.

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

## 7. Remote browser control — parked

`CDPEx.connect/2` drives a Chrome CDPEx didn't launch, but only as a single
connection with `:session` pages: launch options such as `:proxy` can't apply,
nothing restarts a remote Chrome that dies or hangs, and whether `CDPEx.Pool`
works with `launch_opts: [connect: url]` is unchecked. Worth revisiting for
moving Chrome off the application host, a farm of browser hosts behind one pool,
or a cloud browser provider. The remote DevTools endpoint needs TLS and a token
in front of it, since it gives full control of the browser.

## 8. Several pages per pooled browser — idea

`CDPEx.Pool` hands a browser to one job at a time, so 8 parallel jobs run 8
Chromes (an estimated ~3 GB at ~360 MB each). One browser ran 8 concurrent
isolated pages at ~850 MB peak PSS (`bench/`, 4 CPUs). A `pages_per_browser:`
option would let `size: 2, pages_per_browser: 4` serve the same 8 jobs on 2
Chromes. Measure 8×1, 2×4 and 1×8 with `bench/` before building it.
