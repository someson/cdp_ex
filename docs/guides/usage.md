# Usage

## Resource-safe (recommended)

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

## Explicit lifecycle

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

## Transports

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

## Over a pipe instead of a DevTools port

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

## Connecting to an existing Chrome

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

## Under your supervision tree

Because `terminate/2` reaps Chrome, supervise the browser with a `:shutdown`
timeout (not `:brutal_kill`):

```elixir
children = [
  {CDPEx.Browser, name: MyBrowser, headless: true}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Pooling

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

By default a browser serves one job at a time. Where memory is shorter than CPU,
let several jobs share one with `:pages_per_browser`:

```elixir
{CDPEx.Pool, name: MyPool, size: 2, pages_per_browser: 4}
```

This serves 8 parallel jobs on 2 Chromes. In the benchmark
(`docs/design/2026-11-06-pool-pages-per-browser.md`) that took about 44% less memory than `size: 8` for about 20% fewer jobs per
second. A job goes to the least-loaded warm browser with a free slot; the next
browser launches only when every warm one is full. Share browsers through
`with_page/3`: a job holding the whole browser (`with_browser/3`, `checkout/2`)
can stop it or change browser-wide state under the others.
