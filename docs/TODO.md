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

## 8. Several pages per pooled browser — measured, not built

`CDPEx.Pool` hands a browser to one job at a time, so 8 parallel jobs run 8
Chromes. A `pages_per_browser:` option would let `size: 2, pages_per_browser: 4`
serve the same 8 jobs on 2 Chromes.

Measured 2026-11-06 with `bench/` (`concurrent`, 8 workers, isolated pages as in
`Pool.with_page/3`, `BROWSERS` = 8, 2, 1; Docker on an Apple Silicon host,
Chrome for Testing 156 arm64, 3 rounds of 20 s, medians):

| Browsers × pages | CPUs | jobs/s | `new_page` p50 / p95 ms | peak PSS MB | procs | CPU s |
|---|---|---|---|---|---|---|
| 8 × 1 | 8 | 17.6 | 290 / 436 | 1712 | 86 | 116 |
| 2 × 4 | 8 | 13.6 | 254 / 395 | 966 | 34 | 120 |
| 1 × 8 | 8 | 8.6 | 419 / 604 | 831 | 24 | 77 |
| 8 × 1 | 4 | 8.9 | 589 / 799 | 1716 | 86 | 63 |
| 2 × 4 | 4 | 7.2 | 471 / 706 | 960 | 34 | 66 |
| 1 × 8 | 4 | 7.8 | 451 / 664 | 799 | 23 | 67 |

- 2 × 4 takes about 44% less memory than 8 × 1 (≈960 vs ≈1710 MB) for about 20%
  fewer jobs/s, at 4 and at 8 CPUs.
- One browser tops out near 8–9 jobs/s whatever the CPUs: at 8 CPUs 1 × 8 uses
  under 4 of them and its `new_page` p50 rises to ~420 ms. That ceiling is either
  `CDPEx.Browser` serving page setup one call at a time or Chrome's own browser
  process; untested which. With two browsers `new_page` is no slower than with
  eight, so at 4 pages per browser the queue isn't the limit.
- With CPU to spare, a browser costs ~210 MB and lifts throughput; the option
  pays off only where memory, not CPU, is short.

Rerun: `CPUS=8 BROWSERS=2 CONCURRENCY=8 SCENARIOS=concurrent LIBS=cdp_ex
CDP_EX_PAGE_OPTS="[isolated: true]" bench/docker.sh`.

## 9. Proxy login and request interception on one page — done

A page answers the proxy's (or a site's) login and intercepts requests at the
same time, enabled in either order; one `CDPEx.Fetch` process per page owns
the `Fetch` domain and forwards the caller only the pauses matching its
patterns (#24). Design: `docs/design/2026-11-05-fetch-auth-and-interception.md`.
ReqBot can drop the `Fetch.enable` workaround in its interceptor.

## 10. Block resources by type — done

`block: [...]` on `new_page/2` and `Page.block_resources/3`: requests of those
resource types fail with `net::ERR_BLOCKED_BY_CLIENT`, resolved by the page's
`CDPEx.Fetch` process as a third mode next to auth and interception. Design:
`docs/design/2026-11-06-block-resources-by-type.md`. ReqBot can replace its
image/font interceptor with `block:`.

## 11. Full document response from `navigate/3` — done

`headers` and `request_id` in the `response: true` map (see `CHANGELOG.md`).
Kept below for the original problem statement.

`navigate(page, url, response: true)` returns only `%{status, url}`. ReqBot
needs the headers and body of the main document, so it re-implements the
capture: `Network.responseReceived` with `type: "Document"` for the page's
frame, then `Network.loadingFinished`, then `Network.getResponseBody`. Add
`headers` and `request_id` to the returned map so the body can be read with
`response_body/3`. Estimate: 2–3 hours.

## 12. Read a response body without racing `loadingFinished` — done

`body: true` on `wait_for_response/3` (see `CHANGELOG.md`). Kept below for the
original problem statement.

`response_body/3` called between `Network.responseReceived` (what
`wait_for_response/3` resolves on) and `Network.loadingFinished` returns
`{:cdp_error, "Network.getResponseBody", %{"code" => -32000}}` ("No data
found"); the docs tell the caller to retry. ReqBot's capture retries 3 times,
500 ms apart. Add `body: true` to `wait_for_response/3`: wait for this
request's `loadingFinished` (or `loadingFailed`) and return the body with the
response. Estimate: 2–3 hours.

## 13. Cross-site iframes are outside the page's `Fetch` domain — done

Block and login now apply inside cross-site iframes, nested ones included; request
interception covers the page's own frames only (decided). Design:
`docs/design/2026-11-06-cross-site-iframes.md`. Still unverified: whether Chrome
resumes an iframe left waiting if the Fetch owner crashes between its attach and its
resume.

## 14. Gaps found by the competitor comparison

`bench/compare` (see its README) probes every capability for CDPEx,
playwright_ex 0.16, ChromicPDF 1.17 and Wallaby 0.31 by running code. What
the others do and CDPEx doesn't, roughly by how often a scraper needs it:

- ~~**Click lands in a gap.**~~ Done: a trusted click hits the in-view centre
  of the first client rect whose point lands on the element, else
  `{:error, {:obscured, label}}`.
- ~~**Inside an iframe.**~~ Done: `Page.frame/3`, same-site and cross-site.
- ~~**Hover, file upload, JS dialogs.**~~ Done: `Page.hover/3`,
  `Page.set_input_files/4`, `dialogs:` / `Page.set_dialogs/3` /
  `Page.handle_dialog/3`.
- **Downloads.** In playwright_ex (fails in 0.16.0).
- **First click into a just-loaded cross-site iframe is lost.** Chrome drops
  input to an out-of-process iframe until it has painted, a moment after
  `load`; `click/3` hit-tests the `<iframe>` element and returns `:ok`. Seen in
  the dialogs integration test.
- **Console messages.** playwright_ex (context `console` events) and Wallaby
  (`js_logger`).
- **Timezone, clock, tracing.** playwright_ex only (ChromicPDF: timezone).
- **PDF extras.** Header/footer templates, PDF from an HTML string, PDF/A:
  ChromicPDF only.
- **Firefox / WebKit.** playwright_ex (Playwright's builds); Wallaby Firefox only
  through a Selenium 3 server.

Each of these can be done today with raw CDP through `CDPEx.Connection.call/5`,
which is what the probes' notes say; none has an API.
