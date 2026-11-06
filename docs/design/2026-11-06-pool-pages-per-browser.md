# Design: several pages per pooled browser

**Status:** done
**Tracks:** `docs/TODO.md` item 8

## Problem

`CDPEx.Pool` lends each browser to one job at a time, so 8 parallel jobs need
8 Chromes. Where memory, not CPU, is short, fewer browsers serving several jobs
each is the better trade: 2 browsers × 4 pages took about 44% less memory than
8 × 1 for about 20% fewer jobs/s (see Measurements).

## Decisions

- **`pages_per_browser:` start option, default `1`.** A positive integer; any
  other value raises `ArgumentError` from `start_link/1`. With `1` the pool
  behaves as before.
- **A checkout takes one slot.** A browser is lent to up to
  `pages_per_browser` holders at once. `checkout/2`, `with_browser/3` and
  `with_page/3` all count the same way. The pool does not count pages: a holder
  that opens several pages on its browser still holds one slot.
- **A warm slot before a launch.** A checkout goes to the least-loaded browser
  that has a free slot. A browser is launched only when every warm one is full
  and `:size` allows. A cold start costs seconds, a shared browser
  milliseconds, so a pool of `size: 2, pages_per_browser: 4` under 3 jobs runs
  one Chrome; the second comes with the fifth concurrent job and then takes its
  share.
- **An in-flight launch covers `pages_per_browser` waiters.** Five waiters on a
  cold `size: 2, pages_per_browser: 4` pool start two launches, not five; a
  failed launch fails a waiter only when the remaining launches can't cover the
  queue.
- **Each checkout is its own holder.** It has its own owner monitor, so a dead
  owner frees every slot it held, one per checkout. A checkin frees one slot the
  caller holds on that browser; a checkin from a process that holds no slot on
  it is ignored with a warning, as before.
- **A browser that dies drops all its holders.** Their next call on it fails
  (`:noproc`); the pool relaunches on demand as before.

## Consequences callers see

- `with_page/3` keeps `isolated: true` by default, so jobs sharing a browser
  don't see each other's cookies or storage. With `isolated: false` they share
  the default context while running side by side.
- `CDPEx.Browser` serves `new_page/2` one call at a time, so page setup queues
  behind the other holders' (p50 ~250 ms at 4 per browser in the benchmark).
- A holder of `with_browser/3` or `checkout/2` can stop the browser or change
  browser-wide state under the other holders. Use `with_page/3` when sharing.

## Measurements

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

## Not done

- A page cap per browser (counting pages rather than checkouts).
- Retiring a browser after so many jobs, or rebalancing holders.
- Pool telemetry.
- A memory budget that sizes the pool by itself instead of a fixed `:size` and
  `:pages_per_browser`: undecided, a page's memory depends on the site.
