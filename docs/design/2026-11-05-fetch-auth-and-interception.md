# Design: proxy login and request interception on one page

**Status:** done (#24)
**Tracks:** `docs/TODO.md` item 9

## Problem

A page can either answer the proxy's 407 (a credentialed `:proxy`, or
`Page.authenticate/4`) or intercept requests (`enable_request_interception/2`),
not both: the second returns `{:error, {:conflict, :authenticated}}` or
`{:conflict, :intercepting}`. Both drive the page's `Fetch` domain, and two
independent drivers clobber each other: the last `Fetch.enable` wins, and two
subscribers to `Fetch.requestPaused` both resolve every pause. Puppeteer allows
the combination.

ReqBot (blocks images and fonts behind an authenticated proxy) works around it
by re-sending `Fetch.enable` with `handleAuthRequests: true` through
`CDPEx.Connection` and answering `Fetch.authRequired` itself.

## Goals

- Proxy (or HTTP) login and request interception work together on one page, on
  both transports, enabled in either order.
- The caller still receives only the pauses that match its own patterns.
- The anti-brick guarantees stay: an interception owner that dies leaves the
  page usable, and with login still on, the proxy keeps being answered.
- The caller's code does not change: pauses arrive as the same
  `{:cdp_event, conn, "Fetch.requestPaused", params, session_id}` tuple.

## Non-goals

- Answering both a proxy and an origin challenge with different credentials.
- Resource blocking by type (item 10); it builds on this.

## Design

### One `Fetch` owner per page

`CDPEx.Fetch` becomes the single owner of a page's `Fetch` domain. The Browser
starts it on the first auth or interception request for the page and stops it
when the page ends. It has two independent modes:

- **auth**: credentials and `:source`, answering `Fetch.authRequired` as today
  (credentials once per request, `CancelAuth` on a repeat, `Default` for a
  challenge outside `:source`);
- **intercept**: an owner pid (monitored) and its `RequestPattern`s.

The caller of `enable_request_interception/2` no longer subscribes to
`Fetch.requestPaused` itself. The owner forwards each pause meant for it as the
original event tuple, and resolves every other pause with `continueRequest`.
This path is used with and without auth, so there is one code path.

### `Fetch.enable` per mode

| Modes | `patterns` | `handleAuthRequests` |
|---|---|---|
| auth | none (all requests) | true |
| intercept | the caller's | false |
| both | `*` at the Request stage, plus the caller's Response-stage patterns | true |

With auth on, every request must pause: Chrome raises `Fetch.authRequired` only
for intercepted requests. Each mode change re-sends `Fetch.enable`; the last
mode removed sends `Fetch.disable`. The owner stays alive, idle, until the page
ends.

### Which pauses go to the caller

- Intercept only: all of them (Chrome paused exactly the caller's patterns).
- Both, Response stage (`responseStatusCode` or `responseErrorReason`
  present): all of them, since only the caller's patterns pause there.
- Both, Request stage: those matching one of the caller's Request-stage
  patterns by `urlPattern` (`*` any run, `?` one character, `\` escapes) and
  `resourceType`. The matcher is a pure function, compiled once per enable.

Because some patterns are no longer sent to Chrome, `enable_request_interception/2`
validates them itself and returns `{:error, {:invalid_args, {:patterns, value}}}`
for a malformed list.

### Owner death and release

The Fetch owner monitors the interception owner. When it dies, or calls
`disable_request_interception/2`, interception mode is dropped: with auth off
the owner sends `Fetch.disable` (which releases any paused request); with auth
on it continues every pause it forwarded (ids kept in a capped set; a
`continueRequest` for one already resolved fails harmlessly) and re-enables
auth-only.

`Fetch.authRequired` with auth off is ignored, not answered, so ReqBot's
workaround keeps working until it is removed.

### Browser bookkeeping

`auths`, `intercepts` and `pending_auth` become `fetchers` (target id → owner
pid) and `pending` (request tag → parked caller). Requests to the owner are
asynchronous messages carrying a tag; the owner reports each result back to
the Browser, which replies to the parked caller. An owner exit fails every
caller still parked on it. The `authenticate/4` caller is still monitored
(#40): if it departs, the Browser asks the owner to drop that auth.

### API changes

- `{:conflict, :authenticated | :intercepting}` is removed from
  `CDPEx.error_reason/0` and from `classify_error/1`.
- `{:timeout, :enable_request_interception | :disable_request_interception}`
  is added (Browser request timeouts, `:transient` like every `{:timeout, _}`).
- `disable_request_interception/2` no longer needs to run on the enabling
  process, though that stays the recommended use.
- Process label `{:cdp_fetch_auth, source}` becomes `{:cdp_fetch, target_id}`;
  `{:cdp_fetch_disable, conn}` goes away.

## Tests

Unit (no Chrome):

- pattern matching: globs, escapes, `resourceType`, stage detection;
- `Fetch.enable` params for each mode;
- the owner on `FakeCDP`: forward vs continue, owner death with and without
  auth, mode transitions, `authRequired` ignored without auth, session scoping;
- Browser bookkeeping: tagged replies, owner exit, departed auth caller.

Integration (real Chrome, `ProxyAuthServer` serving a page with an image and
reporting the paths it saw):

- credentialed `:proxy` plus image interception: the navigation succeeds, the
  caller sees only the image, fails it, and the proxy never sees the image;
- the same on a `pipe: true` browser's `:session` page;
- interception first, then `authenticate/4`;
- the interception owner dies: the next navigation still passes the proxy;
- `disable_request_interception/2` keeps the proxy login working.
