# CDPEx

[![CI](https://github.com/someson/cdp_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/someson/cdp_ex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

OTP-native [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
browser automation for Elixir. Launch headless Chrome and drive it directly over
CDP, on a WebSocket or on Chrome's stdin/stdout pipe. **No ChromeDriver, no
Node.js.**

```elixir
CDPEx.with_page([], fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
#=> {:ok, "<html>…</html>"}
```

## Why CDPEx?

It drives Chrome over CDP the way Puppeteer and Playwright do, but in pure
Elixir. The browser and each page's CDP connection are **supervised OTP
processes** (a page is a lightweight handle over its connection). A Chrome crash
or a dropped socket comes back to the caller as `{:error, reason}`, not as a hung
session. Every Chrome CDPEx launches is reaped on every exit path: a normal
return, a raise, the caller's death, and the VM itself going away (`System.halt/1`,
`kill -9`, the OOM killer).

It's production-tested: it runs as the sole browser engine for a JavaScript-heavy
scraper, where it replaced a Wallaby/ChromeDriver setup.

| | CDPEx | playwright_ex | ChromicPDF | Wallaby |
|---|---|---|---|---|
| Talks to Chrome over | CDP (WebSocket, or a pipe) | the Playwright Node.js driver | CDP (pipes) | WebDriver |
| Extra process to run | — | Node.js | — | ChromeDriver |
| Scope | general automation | general automation, testing | PDF / screenshots | feature tests |

Its only runtime dependencies are `mint_web_socket`, `jason` and `telemetry`.
What it has built in:

| Feature | Where |
|---|---|
| A page per WebSocket, or many pages multiplexed on the browser's socket | [Transports](#transports) |
| CDP over a pipe, with no DevTools TCP port opened | [Over a pipe](#over-a-pipe-instead-of-a-devtools-port) |
| Attach to a Chrome it didn't launch (`ws://`, `wss://`, `/json/version` discovery) | [Connecting](#connecting-to-an-existing-chrome) |
| A pool of warm browsers, each job in its own browser context | [Pooling](#pooling) |
| A deadline for a whole `with_page/3` call, launch included | [Resource-safe](#resource-safe-recommended) |
| Waits for a selector or a JS predicate that run inside the page, and for a response or network idle | [Page operations](#page-operations) |
| Trusted input: real mouse clicks, key presses, typing | [Page operations](#page-operations) |
| Request interception, network observation, response bodies | [Recipes](docs/guides/recipes.md) |
| Proxy with credentials, HTTP Basic auth | [Recipes](docs/guides/recipes.md#authenticated-proxy) |
| A closed error taxonomy with `transient?/1` for retries | [Error handling](docs/guides/error-handling.md) |
| `:telemetry` events, process labels for `:observer` and LiveDashboard | [Telemetry](docs/guides/telemetry.md), [Process labels](docs/guides/process-labels.md) |

No anti-bot stealth is built in. Presets stay out of scope until a real site
needs them.

## Chrome

CDPEx needs Chrome or Chromium on the host. It finds it via, in order: the
`:chrome_binary` option, `CDP_EX_CHROME_BINARY`, `CHROME_BINARY`, then an OS
default. For reproducible setups, point it at a
[Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/) binary.

> #### Sandbox {: .warning}
>
> CDPEx launches Chrome with `--no-sandbox` by default, since the sandbox can't
> start in many CI/container environments. If you run as root or drive untrusted
> pages, re-enable it by overriding `:args` — see `CDPEx.Chrome`.

The default flags are neutral (stability and headless), not scraping-tuned. Two of
them are there for measured reasons: `--disable-field-trial-config` keeps
Chromium and Chrome for Testing builds from switching on experimental features
(about 30% less memory with 8 concurrent pages; a no-op on branded Google Chrome),
and `--disable-component-extensions-with-background-pages` saves one Chrome
process per browser.

### Running on a server or in a container

CDPEx is validated on macOS and on Linux: CI runs the integration suite against
Chrome stable on Ubuntu 24.04, and `test/docker/` runs it on Ubuntu 26.04 against
Chromium or Google Chrome. `--no-sandbox`, `--disable-dev-shm-usage` and
`--disable-setuid-sandbox` are on by default, so headless Chrome starts out of the
box on a constrained host (e.g. 2 vCPU / 2 GB).

- **`:launch_timeout` is a ceiling.** Readiness is polled and returns as soon as
  Chrome is reachable, so a generous value costs nothing on a fast launch. Raise it
  for slow cold starts: `CDPEx.launch(launch_timeout: 30_000)`.
- **Each launch gets a fresh profile.** The temp `--user-data-dir`
  (`cdp_ex-<os_pid>-<n>`) is removed on stop, so the first navigation pays a cold
  disk cache. For throughput, reuse a long-lived browser or a pool rather than a
  throwaway `with_page([...])` per request, or pass a persistent `:user_data_dir`.
  If the VM dies, Chrome is still killed; its temp profile stays until the next
  launch on the same host and in the same pid namespace removes it.
- **`/dev/shm`.** `--disable-dev-shm-usage` makes Chrome write to `/tmp`, so a
  small `/dev/shm` (Docker's default is 64 MB) is fine. To size it up instead
  (`--shm-size=1g`), drop that flag via `:args`.
- **Memory.** Close pages promptly; each open page, screenshot and PDF adds memory.
  `:session` pages save a socket and a process per page.
- **`--remote-allow-origins`.** Some Chrome builds reject a DevTools WebSocket
  upgrade with a 403 on an `Origin` check. If you hit `{:error, {:ws_upgrade, _}}`,
  add `extra_args: ["--remote-allow-origins=*"]`, or use `pipe: true`.

## Usage

### Resource-safe (recommended)

`with_page/3` opens a page, runs your function, and always tears everything down,
even if the function raises:

```elixir
# Throwaway browser + page for one job:
{:ok, title} =
  CDPEx.with_page([], fn page ->
    {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
    CDPEx.Page.evaluate(page, "document.title")
  end)
```

Per-operation timeouts stack, so a slow page can hold a browser far longer than any
one of them. `deadline:` bounds the whole call, launch included: when it runs out the
browser is torn down underneath `fun` (only the page, for a browser pid you pass in)
and `with_page` returns `{:error, :deadline_exceeded}`. `fun` keeps running in your
process; see `CDPEx.with_page/3` for what can and can't be interrupted.

```elixir
CDPEx.with_page([], &CDPEx.Page.html/1, deadline: 20_000)
```

On a browser pid, `with_page/3` also closes its page when the caller is killed
mid-`fun` (a linked crash, an Oban job timeout).

### Explicit lifecycle

```elixir
{:ok, browser} = CDPEx.launch(headless: true)
{:ok, page}    = CDPEx.new_page(browser)

{:ok, _page} = CDPEx.Page.navigate(page, "https://example.com")
:ok          = CDPEx.Page.wait_for_selector(page, "h1")
{:ok, html}  = CDPEx.Page.html(page)
{:ok, "Example Domain"} = CDPEx.Page.evaluate(page, "document.querySelector('h1').textContent")
{:ok, _png}  = CDPEx.Page.screenshot(page, path: "example.png")

:ok = CDPEx.close_page(browser, page)
:ok = CDPEx.stop(browser)
```

### Transports

`new_page/2` takes `transport:`:

- `:dedicated` (the default on a launched browser): one WebSocket per page. A
  dropped page socket takes only that page.
- `:session`: the page is a flattened CDP session on the browser's connection.
  Fewer sockets and processes; a dropped browser connection takes all of its
  session pages.

Both support every page operation, including `authenticate/4`, request
interception and a `:proxy` with credentials. A connected browser and a
`pipe: true` browser have only `:session` pages.

`isolated: true` opens the page in its own browser context (cookies,
`localStorage`, cache), disposed when the page closes.

### Over a pipe instead of a DevTools port

By default Chrome listens on a local TCP port for DevTools, and any process on
the host that finds the port can drive that browser. `pipe: true` launches Chrome
with `--remote-debugging-pipe` instead: CDP goes over the Port's stdin and
stdout, and no port is opened.

```elixir
{:ok, browser} = CDPEx.launch(pipe: true)
{:ok, page} = CDPEx.new_page(browser)  # a :session page
```

It works with `with_page([pipe: true], fun)` and
`Pool.start_link(launch_opts: [pipe: true])` too. The trade-offs:

- Pages are `:session` pages only: `transport: :dedicated` returns
  `{:error, {:unsupported_transport, :dedicated}}`.
- Chrome's stderr is discarded, so a failed launch carries no stderr excerpt.
- Unix only.
- Startup is about 15 ms faster on Linux and no faster on macOS.

### Connecting to an existing Chrome

Drive a Chrome that CDPEx didn't launch — one you started yourself, a sidecar
container, or a cloud browser provider — with `connect/2`:

```elixir
# An http(s):// base URL is discovered via GET /json/version:
{:ok, browser} = CDPEx.connect("http://localhost:9222")
# …or pass the browser WebSocket URL directly (ws:// or, for a TLS endpoint, wss://):
{:ok, browser} = CDPEx.connect("wss://chrome.example.com/cdp?token=…")

{:ok, page} = CDPEx.new_page(browser)
{:ok, _}    = CDPEx.Page.navigate(page, "https://example.com")

# stop/1 closes the pages YOU opened and disconnects — it never kills that Chrome.
:ok = CDPEx.stop(browser)
```

`wss://` is verified against the OS trust store; pass `:cacertfile` for a private
CA, or `insecure: true` to skip verification. Raise `:discovery_timeout` (default
`5_000` ms) for a slow remote `/json/version`.
`with_page([connect: "http://localhost:9222"], fun)` is the one-shot form.

> **`http(s)://` discovery is IP/localhost only.** Chrome's DevTools HTTP endpoint
> returns **403** for a non-IP/non-`localhost` `Host` (DNS-rebinding protection), so
> for a **named** remote/sidecar/cloud Chrome pass the `ws(s)://` browser URL
> directly.

### Under your supervision tree

Because `terminate/2` reaps Chrome, supervise the browser with a `:shutdown`
timeout (not `:brutal_kill`):

```elixir
children = [
  {CDPEx.Browser, name: MyBrowser, headless: true}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### Pooling

Reuse warm browsers instead of paying a cold launch per job with `CDPEx.Pool`:

```elixir
children = [
  {CDPEx.Pool, name: MyPool, size: 4, launch_opts: [headless: true]}
]
Supervisor.start_link(children, strategy: :one_for_one)

# Borrow a warm browser for one fetch (a pooled drop-in for with_page/3):
CDPEx.Pool.with_page(MyPool, fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
```

Browsers launch lazily up to `:size` and are reused; `checkout/2` blocks (up to
`:checkout_timeout`) when all are busy. Launches are asynchronous, so the pool
stays responsive during a cold start. A caller that crashes returns its browser,
and a crashed browser is relaunched on demand.

Each `CDPEx.Pool.with_page/3` job runs in its own browser context: the cookies,
`localStorage` and cache one job leaves are gone for the next. Pass
`isolated: false` to share the browser's default context, for example to keep a
login between calls. A browser borrowed with `with_browser/3` or `checkout/2` is
reused as is: open its pages with `isolated: true` to keep jobs apart.

## Page operations

| Function | Description |
|---|---|
| `navigate/3` | Go to a URL, waiting for `networkAlmostIdle` (configurable); `response: true` adds the document's status and final URL |
| `wait_for_navigation/2` | Wait for a navigation an action triggered (`load`, `networkAlmostIdle`) |
| `wait_for_selector/3` | Wait until a CSS selector matches, checked in the page on every DOM change |
| `wait_for_function/3` | Wait until a JS expression is truthy, checked on DOM changes and on an interval |
| `wait_for_response/3` | Wait for a network response by URL (fn / `Regex` / substring), optionally around a `:trigger` |
| `wait_for_network_idle/2` | Wait until the network settles (Puppeteer "networkidle") |
| `evaluate/3` | Run JS and return the value (`returnByValue`) |
| `call_function/4` | Call a JS function with JSON-encoded args |
| `text/3` / `attribute/4` | `textContent` / an attribute of the first match, or `nil` |
| `visible?/3` | Whether the first match is rendered and visible |
| `click/3` | Real trusted click on the first match (synthetic via `trusted: false`); `wait:` retries until it exists and has a box |
| `click_text/3` | Click an element by its text content (whitespace-normalized, innermost match) |
| `type/4` | Focus an element and enter text (`Input.insertText`) |
| `press/4` | Press a named key — `Enter`, `Tab`, arrows, … — with real key events |
| `scroll/3` | Scroll the window to `:top`, `:bottom`, or `{x, y}` |
| `html/2` | Full serialized DOM (`document.documentElement.outerHTML`) |
| `screenshot/2` | PNG bytes, or write to `:path` |
| `pdf/2` | Render the page to PDF bytes, or write to `:path` |
| `set_user_agent/3` | Override the UA string, with optional Client-Hints metadata + `Accept-Language` |
| `set_extra_headers/3` | Extra HTTP headers on every later request from the page |
| `set_viewport/4` | Override the viewport size (and device scale factor) |
| `cookies/2` / `set_cookies/3` / `clear_cookies/2` | Read, set, or clear the cookies of the page's browser context (browser-wide for a page that isn't isolated) |
| `observe_network/2` / `stop_observing_network/2` | Stream `Network` request/response events to the caller, or stop |
| `response_body/3` | Fetch a response body by requestId (`Network.getResponseBody`) |
| `enable_request_interception/2` / `disable_request_interception/2` | Pause matching requests for the caller to resolve, or stop |
| `continue_request/3` / `fulfill_request/3` / `fail_request/3` | Resolve a paused request (proceed / synthetic response / fail) |
| `authenticate/4` | Answer a proxy / HTTP Basic auth challenge (call before `navigate/3`) |

Every function is documented in full in `CDPEx.Page`; `mix docs` builds the docs.

## Guides

- [Recipes](docs/guides/recipes.md)
  - [Block or rewrite requests (interception)](docs/guides/recipes.md#block-or-rewrite-requests-interception)
  - [Grab an API response triggered by a click (SPA)](docs/guides/recipes.md#grab-an-api-response-triggered-by-a-click-spa)
  - [Detect a 403 wall, a 404 or a login redirect](docs/guides/recipes.md#detect-a-403-wall-a-404-or-a-login-redirect)
  - [Authenticated proxy](docs/guides/recipes.md#authenticated-proxy)
  - [Keep jobs apart on a shared browser](docs/guides/recipes.md#keep-jobs-apart-on-a-shared-browser)
- [Error handling](docs/guides/error-handling.md): what returns `{:error, _}`, what
  still raises, and classifying reasons for retries.
- [Telemetry](docs/guides/telemetry.md): the events and how to attach to them.
- [Process labels](docs/guides/process-labels.md): how each CDPEx process is named
  in crash reports, `:observer` and LiveDashboard.

## Development

```bash
mix deps.get
mix test                         # unit tests (no Chrome needed)
mix test --include integration   # real-Chrome tests (set CDP_EX_CHROME_BINARY)
mix ci                           # the full gate: format, deps audit, docs, credo, dialyzer, unit tests
```

Integration tests are tagged `:integration` and excluded by default; they launch a
real Chrome and drive it against a local fixture HTTP server.

- `test/docker/` runs them on Ubuntu 26.04 against Chromium or Google Chrome, and
  reports any Chrome process or profile dir a run leaves behind.
- `bench/` compares CDPEx with Playwright on the same Chromium build (cold start,
  an SPA wait, 8 concurrent pages; time, memory and CPU). See `bench/README.md`.
- Design notes live in `docs/design/`.

## Acknowledgements

Built on [`mint_web_socket`](https://hex.pm/packages/mint_web_socket). Inspired by
the production CDP work in [ChromicPDF](https://github.com/bitcrowd/chromic_pdf) and
by Puppeteer's protocol layer.

## License

MIT. See [LICENSE](LICENSE).
