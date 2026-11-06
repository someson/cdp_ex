# Design: block resources by type

**Status:** done
**Tracks:** `docs/TODO.md` item 10

## Problem

Scrapers commonly skip images, fonts, media and stylesheets: fewer bytes through
a paid proxy and faster loads. Today a caller builds this from
`enable_request_interception/2` plus a process of its own that fails every pause
(see the image-blocking example in `docs/guides/recipes.md`). That process is
needed because the caller is blocked in `navigate/3` while the pauses arrive, and
every caller that wants blocking writes the same loop. ReqBot does exactly this.

Since #24 one `CDPEx.Fetch` process per page owns the `Fetch` domain and already
resolves the pauses nobody else wants. Failing a pause by resource type is one
more decision in that process, so no caller-side process is needed.

## Goals

- `block: [:image, :font, :media, :stylesheet]` on a page fails requests of those
  types with `net::ERR_BLOCKED_BY_CLIENT` before they reach the network.
- No process on the caller's side: the library resolves the pauses.
- Combines with proxy/HTTP login and request interception on the same page, in
  any order, on both transports.
- Works through `CDPEx.Pool.with_page/3` and `CDPEx.with_page/3` with no extra
  code (both forward page options to `new_page/2`).
- Without login on the page, only the blocked types pause, so the cost is one
  round trip per blocked request and none for the rest.

## Non-goals

- Blocking by URL, domain or pattern. Request interception covers that.
- A launch- or pool-wide default. `Pool.with_page(pool, fun, block: [...])`
  covers the Pulse case; revisit if callers repeat it everywhere.
- Counting or reporting blocked requests (telemetry). Can be added later.
- Anti-bot considerations. Blocking is a bandwidth feature, not stealth (#35).

## Design

### API

Two entry points, one mechanism:

- **`new_page/2` option `:block`** (and so `with_page/3` and `Pool.with_page/3`):
  armed before the page is returned, the same way a credentialed `:proxy` is
  armed today, so the first `navigate/3` is already filtered.
- **`CDPEx.Page.block_resources(page, types, opts \\ [])`**: sets the page's
  blocked types at runtime. It replaces the previous set; `[]` turns blocking off.
  Returns `:ok` once the new `Fetch.enable` is in effect. `:timeout` option as on
  the other Fetch calls.

`types` is a list of atoms mapped to CDP `Network.ResourceType`:

| Atom | CDP |
|---|---|
| `:image` | `Image` |
| `:font` | `Font` |
| `:media` | `Media` |
| `:stylesheet` | `Stylesheet` |
| `:script` | `Script` |
| `:xhr` | `XHR` |
| `:fetch` | `Fetch` |
| `:text_track` | `TextTrack` |
| `:manifest` | `Manifest` |
| `:prefetch` | `Prefetch` |
| `:ping` | `Ping` |
| `:event_source` | `EventSource` |
| `:other` | `Other` |

`:document` is rejected as a `:block` value (documents still load normally):
blocking it would fail the page's own navigation, and CDP gives iframes the same
`Document` type, so blocking iframes is left to request interception by URL. A
`:websocket` atom is rejected too: the `Fetch` domain never pauses WebSocket
handshakes, so it would silently do nothing. Anything outside the table, or a
value that is not a list, returns `{:error, {:invalid_args, {:block, value}}}`
from both entry points (from `new_page/2` before any target is created).

Block mode has no owner process. Unlike interception, nobody has to answer the
pauses, so there is nothing to brick if the caller dies; blocking lasts until it
is changed or the page ends. Calling `block_resources/3` from any process is fine,
and there is no `:already_blocking` error.

### A third mode in `CDPEx.Fetch`

`CDPEx.Fetch` gains a **block** mode next to auth and intercept: a set of CDP
resource type strings, `nil` when off. `{:block, types}` is a new
`Fetch.request/3` message; an empty list sets the mode to `nil`. Every change goes
through the existing `rearm/3`.

`Fetch.enable` params, extending the table in the #24 design:

| Modes on | `patterns` | `handleAuthRequests` |
|---|---|---|
| block | one Request-stage pattern per blocked type | false |
| block + intercept | the blocked types' patterns, then the caller's | false |
| auth (with or without the others) | as today: `*` at Request, plus the caller's Response-stage patterns | true |

### Deciding a pause

One pure function replaces `forward?/2`:
`decide(state, params) :: :block | :forward | :continue`, applied in this order:

1. A Request-stage pause whose `resourceType` is in the block set → `:block`:
   `Fetch.failRequest` with `errorReason: "BlockedByClient"`.
2. Interception on and the pause is the owner's → `:forward`. Chrome paused
   exactly the owner's patterns only when both auth and block are off; otherwise
   match the Request-stage pause against the owner's compiled matchers, as #24
   does for auth. Response-stage pauses are always the owner's.
3. Otherwise → `:continue`.

Block wins over interception: a blocked type never reaches the interception
owner, even if its patterns match it. This is the answer to "why didn't my
interceptor see the image": the page asked not to load it. The docs state it.

### Interception release with block on

#24 continues the owner's already-forwarded pauses before re-enabling only when
auth stays on; with auth off it relies on `Fetch.disable` releasing them. With
block on, dropping interception re-enables instead of disabling, so those pauses
would stay stuck. `drop_intercept/2` therefore continues the forwarded pauses
whenever any mode stays on (auth or block), not only auth.

### Browser

`new_page/2` validates `:block` first. After the page is created (and after the
proxy auth arm, if any), a non-empty `:block` is armed synchronously with the
same await-the-owner path as `reply_proxy_authed_page`, under the existing
`@arm_timeout`. A failure closes the just-created page and returns the error.
Two `Fetch.enable` calls on a proxied page with `:block` are acceptable; merging
them into one request is the builder's call.

`block_resources/3` goes through a `{:block, page, types, timeout}` call that
parks the caller in `pending` like `:intercept`, with no caller monitor (no
owner semantics). An unknown page returns `{:error, :unknown_page}`.

### Error taxonomy

- `{:invalid_args, {:block, value}}` — already covered by `{:invalid_args, _}`.
- `{:timeout, :block_resources}` — added to the `{:timeout, ...}` union in
  `CDPEx.error_reason/0` with an exemplar in `test/cdp_ex_test.exs`; classified
  `:transient` like every `{:timeout, _}`. As with interception, a timed-out
  `block_resources/3` may still take effect later; the caller can call it again.

## Docs

- `docs/guides/recipes.md`: the image-blocking example from #24 becomes
  `CDPEx.new_page(browser, block: [:image])`; the hand-written owner loop moves to
  a "custom rule" note pointing at `enable_request_interception/2`.
- `docs/guides/page-operations.md`: a row for `block_resources/3`.
- `CDPEx.Browser.new_page/2` and `CDPEx.Fetch` moduledocs: the new mode.
- `CHANGELOG.md` under `[Unreleased]`; `docs/TODO.md` item 10 marked done.

## Tests

Unit (no Chrome):

- type validation: each atom, `:document`, `:websocket`, unknown atom, non-list;
- `Fetch.enable` params for every mode combination;
- `decide/2`: block before forward, Response stage never blocked, matching with
  block on and auth off;
- the owner on `FakeCDP`: blocked pause gets `failRequest` with
  `BlockedByClient`, `[]` disables, interception release with block on continues
  the forwarded pauses;
- Browser: `new_page(block: ...)` arms before returning, a failed arm closes the
  page, invalid `:block` creates no target.

Integration (real Chrome, a fixture page with an image, a font and a
stylesheet; the server reports the paths it saw):

- `block: [:image, :font]`: navigation succeeds, the server never sees the
  image or the font, the stylesheet loads;
- the same on a `pipe: true` browser's `:session` page;
- credentialed `:proxy` plus `block:` through `ProxyAuthServer`: the proxy never
  sees the image;
- `block:` plus interception of stylesheets: the owner sees only the
  stylesheet, never the image;
- `block_resources(page, [])` lets the image through on the next navigation;
- `Pool.with_page(pool, fun, block: [:image])`.
