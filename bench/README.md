# Benchmark

Runs the same scenarios through CDPEx and Playwright against a local fixture
server, so a change can be checked against a fixed baseline. Not part of the Hex
package (`mix.exs` lists the packaged files). For CDPEx against the other Elixir
libraries (playwright_ex, ChromicPDF, Wallaby), see `compare/README.md`.

```bash
bench/docker.sh                    # Linux container, 4 CPUs, Chromium: the reference setup
CDP_EX_CHROME_BINARY=... bench/run.sh   # on the host, with the browser you point it at
```

`docker.sh` builds the `test/docker` Chromium image, adds `playwright-core` on
top, and runs `run.sh` in it. Both libraries then drive the same Chromium build
(Playwright's, the version pinned in `test/docker/Dockerfile` and here in
`package.json`). Results land in `bench/results/<timestamp>/` (ignored by git):
one JSON line per run in `results.jsonl`, the table in `table.md`, each run's
output and stderr next to them.

On the host, run `npm ci` in `bench/` first. Memory and CPU are sampled only on
Linux; elsewhere those columns stay empty.

## Scenarios

Every page is loaded with `wait_until: :load` (Playwright's `goto` default).

| Scenario | What one sample is |
|----------|--------------------|
| `cold` | launch → new page → load `/` → read the title → stop. The first cycle is a warm-up and isn't counted. |
| `spa` | On one warm browser: new page → load `/spa` → wait for `.item`, which the page renders from a 20 ms JSON API after load → close the page. |
| `concurrent` | On one warm browser, `CONCURRENCY` workers run `/` page jobs back to back for `DURATION_S` seconds. Reports jobs/s. |

Each library runs with its own defaults. That isn't the same page setup:
Playwright's `browser.newPage()` opens a fresh context per page, CDPEx's
`new_page/2` reuses the default context over a dedicated WebSocket. Pass
`CDP_EX_PAGE_OPTS="[isolated: true]"` for a context per page on the CDPEx side
too, which is what `CDPEx.Pool.with_page/3` does by default.

## Columns

- **p50 / p95 ms** of the samples within a round.
- **jobs/s** for `concurrent`.
- **peak PSS MB**, **peak procs**: the largest sum of PSS over all processes
  running the browser binary, and the most such processes, sampled every
  `INTERVAL_MS`.
- **CPU s**: user + system time of those processes. A process shorter than one
  interval is missed, so compare runs with each other, not with other tools.

Each figure is the median over rounds.

## Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `ROUNDS` | `3` | Rounds; each runs every scenario for every library |
| `SCENARIOS` | `cold spa concurrent` | Scenarios to run |
| `LIBS` | `cdp_ex playwright` | Libraries to run |
| `ITERATIONS` | `10` (`cold`), `20` (`spa`) | Samples per round |
| `DURATION_S` | `20` | Length of a `concurrent` run |
| `CONCURRENCY` | `8` | Workers in `concurrent` |
| `BROWSERS` | `1` | Browsers the `concurrent` workers are spread over, round-robin (CDPEx only); the result also carries each job's `new_page/2` p50/p95 |
| `CDP_EX_LAUNCH_OPTS` | `[]` | Elixir keyword list passed to `CDPEx.launch/1`, e.g. `[pipe: true]` |
| `CDP_EX_PAGE_OPTS` | `[]` | Elixir keyword list passed to `CDPEx.new_page/2`, e.g. `[isolated: true]` |
| `INTERVAL_MS` | `100` | Sampler interval |
| `CPUS` | `4` | CPU cap for the container (`docker.sh` only) |
| `RESULTS` | `bench/results/<timestamp>` | Output dir (`run.sh` only) |

## Comparing against older numbers

Numbers published up to #13 came from an earlier harness that was not kept: a
native 4 vCPU Linux host and Chromium build 1243. This one runs in a container
with the same CPU cap and a newer Chromium, so its absolute numbers differ. Compare a change against a run of this harness on `main`, on the same
machine.

## Reference run

`bench/docker.sh` on `main` after #13, 2026-11-05: Apple Silicon host, Docker
Desktop, 4 CPUs, Chrome for Testing 156.0.8078.4 (arm64), Elixir 1.20.5 / OTP 27,
Node 22, 3 rounds.

| Scenario | Library | p50 ms | p95 ms | jobs/s | peak PSS MB | peak procs | CPU s |
|---|---|---|---|---|---|---|---|
| cold | cdp_ex | 269 | 286 | – | 380 | 11 | 5.1 |
| cold | playwright | 224 | 257 | – | 350 | 9 | 3.6 |
| spa | cdp_ex | 69 | 74 | – | 396 | 11 | 2.9 |
| spa | playwright | 132 | 143 | – | 373 | 9 | 5.7 |
| concurrent | cdp_ex | – | – | 23.8 | 503 | 17 | 48.7 |
| concurrent | playwright | – | – | 7.4 | 807 | 23 | 60.5 |

`concurrent` compares different page setups (see Scenarios): Playwright opens a
context per page, CDPEx here doesn't.
