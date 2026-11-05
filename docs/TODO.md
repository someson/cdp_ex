# TODO

Open work found while benchmarking CDPEx against Playwright and fixing what
that turned up. Ordered by priority. Every number below comes from the same
benchmark setup unless noted: a 4 vCPU / 16 GB Linux container, Chromium build
1243 (Playwright's bundle) for both libraries, headless, a local fixture server,
3 rounds, medians.

## 1. Per-job isolation (browser contexts)

**Problem.** A pooled browser is reused as is. With a size-1 `CDPEx.Pool`, a
second `Pool.with_page/3` call saw the first job's cookie and `localStorage`
entry. `Page.cookies/2` and `Page.clear_cookies/2` are browser-wide
(`Network.getAllCookies`, `Network.clearBrowserCookies`), and there is no
built-in way to reset storage. The README warns about this; it doesn't fix it.

**Direction.** Open each page in its own browser context
(`Target.createBrowserContext`, then `Target.createTarget` with that
`browserContextId`) and dispose the context
(`Target.disposeBrowserContext`) when the page closes. Playwright does this:
each context has its own cookies, storage and cache. Likely an option on
`new_page/2` and `with_page/3` first, then the default for `Pool.with_page/3`.

**Open questions.** Cost of a context per job (time and memory, to measure);
how it interacts with the `:dedicated` and `:session` transports and with
`connect/2`; whether `cookies/2` should become per-context.

Write a design note in `docs/design/` before implementing.

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

## 3. Cold start: pipe transport

**Problem.** A cold launch → page → navigate → stop cycle is still slower than
Playwright: 532 ms vs 458 ms at p50. Playwright talks to Chrome over
`--remote-debugging-pipe` and knows it is ready at once; CDPEx waits for the
`DevTools listening on` stderr line, polling `DevToolsActivePort` every 150 ms
as a fallback, then opens a WebSocket.

**Direction.** A pipe transport: Chrome reads CDP on fd 3 and writes on fd 4,
as NUL-delimited JSON. A Port only gives fd 0/1, so it needs the same kind of
`/bin/sh` wrapper the watchdog already uses (`exec 3<&0 4>&1`). ChromicPDF
does this. Side benefits: no TCP port is opened, and Chrome exits on its own
when the pipe closes.

**Cost.** A second transport next to the WebSocket one, with its own framing,
session handling and tests. Worth it only if cold start matters; a warm
`CDPEx.Pool` hides it.

## 4. Default flags: what hasn't been measured

- `--disable-field-trial-config` (on by default since #1) was measured on
  Chromium only. Branded Google Chrome stable doesn't apply the field-trial
  testing config, so the flag should be close to a no-op there. Confirm.
- `--disable-component-extensions-with-background-pages` was the only other
  flag with a visible effect in the bisection (8 concurrent pages: 15.2 vs
  13.9 jobs/s, 27 vs 29 Chrome processes). Weak evidence; re-measure on top
  of `--disable-field-trial-config` before adding it.

## 5. Keep the benchmark reproducible

The numbers in `CHANGELOG.md` and the PR descriptions came from a harness that
isn't in this repository: a Node fixture server, matching CDPEx and Playwright
scenario scripts, and a runner that samples PSS and CPU from `/proc`. Add it
under `bench/` (outside the Hex package) with a short README, so a change can
be checked against the same scenarios.

## 6. Upstream

Changes in this fork that `patrols/cdp_ex` doesn't have yet: the
`--disable-field-trial-config` default (#1), reaping Chrome when the VM exits
(#2), unique temp profile dirs (#3), in-page waits (#4), the README fixes
(#5), and sweeping stale temp profile dirs (#8). Upstream requires signed commits, so they need re-signing before being
offered there, and the PR numbers in `CHANGELOG.md` will differ.
