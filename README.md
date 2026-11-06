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
| Scope | general automation | general automation, testing | PDF / screenshots | feature tests |
| Talks to the browser over | CDP (WebSocket, or a pipe) | the Playwright Node.js driver | CDP (pipes) | WebDriver |
| Extra process at runtime | none | Node.js (Playwright) | none | ChromeDriver, or Selenium |
| Browsers | Chrome / Chromium | Chromium, Firefox, WebKit | Chrome / Chromium | Chrome; Firefox only through a Selenium 3 server |
| Pool of warm sessions | ✓ browsers (`CDPEx.Pool`) | ✗ | ✓ tabs (`session_pool`) | ✗ |
| Per-job isolation | ✓ a browser context per job | ✓ `new_context` | ✗ | ✓ a session (a Chrome) per job |
| Attach to a running Chrome | ✓ `connect/2` | ✗ (a remote Playwright server only) | ✓ `chrome_address` (experimental) | partial (ChromeDriver's `debuggerAddress`) |
| Request interception | ✓ | ✓ `route` | ✗ | ✗ |
| Block resources by type | ✓ `block:`, cross-site iframes included | partial (a `route` handler) | ✗ | ✗ |
| Site login / proxy with credentials | ✓ / ✓ (cross-site iframes included) | ✓ / ✓ | ✗ / ✗ | ✗ / ✗ |
| Waits | selector, JS predicate, network idle, a response with its body | selector, JS predicate, network idle; responses without a body | partial (an element via an `:evaluate` Promise) | element queries |
| Read text, click, fill a form | ✓ | ✓ | ✗ | ✓ |
| Hover | ✓ `hover/3` | ✓ | ✗ | ✓ |
| File upload, JS dialogs | ✗ | ✓ | ✗ | ✓ |
| Downloads | ✗ | fails in 0.16.0 (the documented flow raises) | ✗ | ✗ |
| Inside an iframe | ✗ | ✓ | ✗ | ✓ |
| Console messages | ✗ | ✓ | ✗ | ✓ |
| Timezone / clock / tracing | ✗ / ✗ / ✗ | ✓ / ✓ / ✓ | partial / ✗ / ✗ | ✗ / ✗ / ✗ |
| Screenshots / PDF | ✓ / ✓ | ✓ / partial (raw protocol) | ✓ / ✓ | ✓ / ✗ |
| PDF/A, header/footer, PDF from an HTML string | ✗ | ✗ | ✓ | ✗ |
| `:telemetry` events | ✓ | ✗ | ✓ | ✗ |

Every capability cell is a probe result, not a reading of the docs: `bench/compare`
runs each one against a fixture page and checks the output (November 2026:
playwright_ex 0.16.0, ChromicPDF 1.17.2, Wallaby 0.31.0, Chromium 156). ✓ means
done through the library's API, partial only by a workaround, ✗ no way in its
API. The same harness times the four on the same tasks and pages; the numbers
are in `bench/compare/README.md` in the repository. CDPEx's only runtime
dependencies are `mint_web_socket`, `jason` and `telemetry`. More in
[Usage](#usage) and [Guides](#guides).

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

They also turn off Chrome's own background calls to Google (sync, metrics, network
time, optimization hints, Safe Browsing real-time lookups, the search preconnect),
and `accounts.google.com` and `update.googleapis.com` never reach the network
(`:block_background_hosts`, on by default). Behind a paid proxy that is no request
to Google instead of 14 in the first 20 seconds (Google Chrome 157, Linux). See
`CDPEx.Chrome`.

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

- [Resource-safe `with_page/3`](docs/guides/usage.md#resource-safe-recommended), with a deadline for the whole call
- [Explicit lifecycle](docs/guides/usage.md#explicit-lifecycle): `launch/1`, `new_page/2`, `close_page/2`, `stop/1`
- [Transports](docs/guides/usage.md#transports): a WebSocket per page, or pages multiplexed on the browser's socket; isolated pages
- [Over a pipe instead of a DevTools port](docs/guides/usage.md#over-a-pipe-instead-of-a-devtools-port)
- [Connecting to an existing Chrome](docs/guides/usage.md#connecting-to-an-existing-chrome)
- [Under your supervision tree](docs/guides/usage.md#under-your-supervision-tree)
- [Pooling](docs/guides/usage.md#pooling), each job in its own browser context
- [Page operations](docs/guides/page-operations.md): navigation, waits, evaluation, input, screenshots and PDFs, cookies, network, interception, resource blocking, auth

## Guides

- [Recipes](docs/guides/recipes.md)
  - [Block or rewrite requests (interception)](docs/guides/recipes.md#block-or-rewrite-requests-interception)
  - [Grab an API response triggered by a click (SPA)](docs/guides/recipes.md#grab-an-api-response-triggered-by-a-click-spa)
  - [Detect a 403 wall, a 404 or a login redirect](docs/guides/recipes.md#detect-a-403-wall-a-404-or-a-login-redirect)
  - [Authenticated proxy](docs/guides/recipes.md#authenticated-proxy), with resource blocking to save its traffic
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
