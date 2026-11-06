# TODO

Open work found while benchmarking CDPEx against Playwright and fixing what
that turned up, ordered by priority. Numbers are kept stable, so closed items
stay as one line. Unless noted, measurements come from a 4 vCPU / 16 GB Linux
container, Chromium build 1243 (Playwright's bundle) for both libraries,
headless, a local fixture server, 3 rounds, medians.

## Done

1. Per-job isolation (browser contexts): `isolated: true` (#12).
3. Pipe transport: `pipe: true` (#13). `docs/design/2026-11-05-pipe-transport.md`.
4. Default flags: `--disable-field-trial-config` kept, and
   `--disable-component-extensions-with-background-pages` added (#15): one Chrome
   process and about 13 MB less at cold start.
5. Reproducible benchmark: `bench/` (see `bench/README.md`).
9. Proxy login and request interception on one page (#24).
   `docs/design/2026-11-05-fetch-auth-and-interception.md`.
10. Block resources by type: `block:` (#25).
    `docs/design/2026-11-06-block-resources-by-type.md`.
11. Full document response from `navigate/3`: `headers` and `request_id` (#29).
12. Response body without racing `loadingFinished`: `body: true` on
    `wait_for_response/3` (#28).
13. Block and login inside cross-site iframes (#30).
    `docs/design/2026-11-06-cross-site-iframes.md`.

## 2. Empty profile dir left by a launch cut short — parked

The integration test "a real launch cut short by the capped launch_timeout"
(`with_page([], fun, deadline: 50)`) sometimes left an empty `cdp_ex-*` dir in
the temp dir (7 of 20 runs before #2 and #3, 2 of 20 with them); no Chrome
process was left. Suspected cause: Chrome's children briefly outlive the
browser process and recreate the dir after `remove_dir/1` (5 retries, 50 ms
apart) has deleted it.

Not reproduced on current main (2026-11-05): 0 leftover dirs in 180 runs across
macOS Google Chrome, Chrome for Testing 156 arm64 and Google Chrome 157 amd64
in `test/docker/`, with and without `strace`, which showed only the BEAM creating
the dir. If a leftover dir shows up again, rerun `TRACE=1 test/docker/run.sh`;
the fix would be to wait for the whole Chrome process group to exit before
removing the dir, or to retry removal for longer.

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
`Pool.with_page/3`; Docker on an Apple Silicon host, Chrome for Testing 156
arm64, 3 rounds of 20 s, medians):

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
  process; untested which.
- With CPU to spare, a browser costs ~210 MB and lifts throughput; the option
  pays off only where memory, not CPU, is short.

Rerun: `CPUS=8 BROWSERS=2 CONCURRENCY=8 SCENARIOS=concurrent LIBS=cdp_ex
CDP_EX_PAGE_OPTS="[isolated: true]" bench/docker.sh`.

## 13a. An iframe left paused if the Fetch owner dies — unverified

Whether Chrome resumes a cross-site iframe left waiting if the page's
`CDPEx.Fetch` process crashes between the iframe's attach and its resume.

## 14. Gaps found by the competitor comparison

`bench/compare` (see its README) probes every capability for CDPEx,
playwright_ex 0.16, ChromicPDF 1.17 and Wallaby 0.31 by running code. Closed:
the click in a line gap, iframes, hover, file upload, JS dialogs, console
messages, downloads (#42) and the lost first click into a just-loaded
cross-site iframe (#43). Still open, roughly by how often a scraper needs it:

- **PDF extras.** Header/footer templates, PDF from an HTML string, PDF/A:
  ChromicPDF only.
- **Firefox / WebKit.** playwright_ex (Playwright's builds); Wallaby Firefox only
  through a Selenium 3 server.

Each can be done today with raw CDP through `CDPEx.Connection.call/5`; none has
an API.
