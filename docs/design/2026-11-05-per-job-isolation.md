# Design: per-job isolation with browser contexts

**Status:** draft, pending review
**Tracks:** `docs/TODO.md` item 1

## Problem

A pooled browser is reused as is. With a size-1 `CDPEx.Pool`, a second
`Pool.with_page/3` call sees the first job's cookies and `localStorage`,
including a logged-in session. `Page.cookies/2` and `Page.clear_cookies/2` act
on the whole browser, and storage has no reset at all. The README warns about
this but offers no fix short of a browser per job, which gives up the pool's
warm start.

Chrome already has the right unit of isolation: a browser context
(`Target.createBrowserContext`). Each context has its own cookies, storage,
cache and permissions, and costs far less than a new Chrome. Playwright opens
one per `newContext()`; Puppeteer per `createBrowserContext()`.

## Goals

- A page can be opened in its own, fresh browser context, which is disposed when
  the page closes, on every exit path (normal close, `with_page/3` return or
  raise, deadline, caller death, tab crash, browser stop).
- `Pool.with_page/3` isolates jobs by default.
- Works on both transports (`:dedicated`, `:session`) and on connected
  browsers (`CDPEx.connect/2`).
- Cookie functions called on an isolated page act on that page's context only.

## Non-goals

- A public context handle shared by several pages (Playwright's
  `BrowserContext` with many pages). The option below leaves room for it.
- Per-context proxy (`createBrowserContext` takes `proxyServer`). Separate
  feature; the browser-level `:proxy` keeps working inside contexts.
- Per-context permissions, downloads, geolocation, user agent.
- Isolation for `Pool.with_browser/3` / `checkout/2`: the caller holds the
  browser and opens pages itself, so it passes the option itself.

## Anti-goals

- A context left behind. A leaked context keeps its storage and memory for the
  life of the browser, which on a pool is the life of the VM. This is the same
  class of bug as an orphaned Chrome and is treated the same way.
- A cookie call on an isolated page that silently reads or clears the default
  context.

## Evidence

Probed against Google Chrome stable on macOS, 2026-11-05 (scripts not kept;
numbers are medians of 20):

- `Network.getAllCookies`, `Network.setCookies` and
  `Network.clearBrowserCookies` sent on a page's session act on **that page's
  context**: a context page did not see a default-context cookie, a cookie set
  in the context did not appear in the default context, and clearing in the
  context left the default context's cookie in place. So `Page.cookies/2`,
  `set_cookies/3` and `clear_cookies/2` become per-context with no code change.
- `Target.disposeBrowserContext` closes the context's targets.
- Cost per job:

  | Step | ms |
  |------|----|
  | `createBrowserContext` | 4 |
  | `createTarget` in a new context | 63 (32 in the default context) |
  | `closeTarget` in a context | 34 (5 in the default context) |
  | `disposeBrowserContext` | 10 |

  About +75 ms per page against the default context, small next to a
  navigation.

- Measured again through `new_page/2` / `close_page/2` once implemented (`:session`,
  medians of 20; Linux is `test/docker/` Chromium arm64 capped to 4 CPUs, two runs):

  | | open, plain | open, isolated | close, plain | close, isolated |
  |---|---|---|---|---|
  | macOS, Google Chrome | 40 | 153 | 1 | 8 |
  | Linux, Chromium | 28–31 | 91–108 | 1–2 | 9–10 |

  Disposing the context alone (it closes the target) took 8 ms against 20 ms for
  `closeTarget` then dispose on macOS, and 9–10 against 7–13 on Linux, so
  `close_page/2` only disposes.

## API

`CDPEx.new_page/2` (and so `CDPEx.with_page/3` on a browser pid, and
`Pool.with_page/3`, which forward page options) gains:

- `:isolated` — `true` opens the page in a new browser context that is disposed
  when the page closes. Default `false`, except in `Pool.with_page/3`, where it
  defaults to `true`; pass `isolated: false` there to share the browser's
  default context as before.

`CDPEx.with_page/3` with launch options (a throwaway browser) accepts the
option but gains nothing from it; the default stays `false`.

`CDPEx.Page` gains no field: whether a page is isolated is tracked in the
Browser, which is the only process that creates and disposes contexts.

Telemetry: the `[:cdp_ex, :page, :start | :stop]` metadata gains
`isolated: boolean()`.

No new `error_reason/0` member: a failed context command returns the CDP error
the same way a failed `Target.createTarget` does today.

## Internals

All in `CDPEx.Browser`.

- **State:** `contexts: %{target_id => browser_context_id}`.
- **Open:** for `isolated: true`, `Target.createBrowserContext` with
  `disposeOnDetach: true`, then `Target.createTarget` with that
  `browserContextId`, then the existing dedicated or session setup. Any failure
  after the context exists disposes it, the same way `open_target/3` closes a
  target it can't finish.
- **Close:** `close_page/2` on an isolated page disposes the context instead of
  calling `Target.closeTarget`; dispose closes the target. The dedicated page
  connection is then stopped as today. Whether dispose alone is faster than
  close + dispose is measured; the code takes whichever is faster.
- **Target gone without close_page:** a dedicated page connection's `EXIT` and a
  session's `Target.detachedFromTarget` (tab crash, closed from outside) also
  dispose the page's context, so a crashed job doesn't leak one.
- **Browser stop:** a launched browser needs nothing extra (Chrome dies with
  its contexts). A connected browser disposes its contexts in `terminate/2`,
  next to the targets it already closes there.
- **VM death on a connected browser:** `disposeOnDetach: true` makes Chrome
  dispose the context when the browser WebSocket that created it drops, so a
  `kill -9` of our VM doesn't leave contexts on a remote Chrome.
- **Proxy auth:** a launched browser with `:proxy` credentials arms Fetch auth
  per page; contexts inherit the browser's `--proxy-server`. Covered by an
  integration test.
- **Deadline / caller death:** unchanged paths: they end in `close_page/2`,
  which disposes. A caller that dies while `new_page/2` is in flight leaves the
  page open today; with `:isolated` its context stays too, until the browser
  stops.

## Tests

Unit (fake connection): option validation; context disposed on close, on each
open failure stage, on page-conn `EXIT`, on `detachedFromTarget`, and in
connected `terminate/2`.

Integration (real Chrome), both transports:

- cookie and `localStorage` set in one isolated page are not visible in the next
  one, on a size-1 pool;
- `Page.cookies/2` / `clear_cookies/2` on an isolated page leave the default
  context alone;
- no context is left after close, raise in `fun`, deadline, and a crashed tab
  (`Target.getBrowserContexts` is empty again);
- an isolated page works through an authenticated proxy;
- `connect/2` + isolated page, then `stop/1`: the remote Chrome has no context
  of ours left.

## Docs

- README: replace the "Borrowers share browser state" warning with the
  isolation default and `isolated: false`.
- `Page.cookies/2` and friends: "the page's browser context" instead of
  "browser-wide"; the README table row likewise.
- CHANGELOG `[Unreleased]`: `Pool.with_page/3` isolates jobs by default
  (behaviour change), and the new `:isolated` option.

## Decisions

1. `Pool.with_page/3` isolates by default. This changes behaviour for users that
   rely on a shared login across jobs; they pass `isolated: false`.
2. The option is `isolated: boolean()`. A shared context handle, if ever
   needed, gets its own option.
