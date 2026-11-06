# Recipes

End-to-end patterns for the event-driven features. Each `CDPEx.Page` function is
documented in full in its module docs (`mix docs` builds them).

## Block or rewrite requests (interception)

Interception is event-driven: the process that enables it receives one
`Fetch.requestPaused` event per request and must resolve every one — with
`continue_request/3`, `fulfill_request/3`, or `fail_request/3`. Drive it from a single
long-lived process: an unresolved request stalls the page, so disable interception
before that process stops resolving, or the page's next request hangs.

It combines with `authenticate/4` and a credentialed `:proxy`: the library answers the
login and lets through the requests outside `:patterns`, so the loop below still sees
only the ones it asked for. To drop whole resource types (images, fonts), use
`block:` instead (see "Use a proxy" below); no loop is needed.

```elixir
defmodule ImageBlocker do
  # Drops image requests; lets everything else through.
  def run(page) do
    :ok = CDPEx.Page.enable_request_interception(page)
    loop(page)
  end

  defp loop(page) do
    receive do
      {:cdp_event, _conn, "Fetch.requestPaused", %{"requestId" => id, "request" => request}, _sid} ->
        if String.ends_with?(request["url"], [".png", ".jpg", ".webp"]) do
          CDPEx.Page.fail_request(page, id, reason: :blocked_by_client)
        else
          CDPEx.Page.continue_request(page, id)
        end

        loop(page)
    after
      # Idle for a second: stop intercepting, then let through any request that
      # paused just before the disable.
      1_000 ->
        :ok = CDPEx.Page.disable_request_interception(page)
        drain(page)
    end
  end

  defp drain(page) do
    receive do
      {:cdp_event, _conn, "Fetch.requestPaused", %{"requestId" => id}, _sid} ->
        _ = CDPEx.Page.continue_request(page, id)
        drain(page)
    after
      0 -> :ok
    end
  end
end
```

## Grab an API response triggered by a click (SPA)

Pass the action as `:trigger`: the wait is registered before it runs, so a response
that arrives while the click is still in flight is caught. The matcher is a substring,
a `Regex`, or a `(url -> boolean)` function.

```elixir
CDPEx.with_page([], fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com/app")

  {:ok, %{"requestId" => id, "response" => %{"status" => 200}}} =
    CDPEx.Page.wait_for_response(page, ~r{/api/items},
      trigger: fn -> CDPEx.Page.click(page, "#load-more") end
    )

  CDPEx.Page.response_body(page, id)
end)
```

When you just need the page to settle after hydration (no specific response to match),
use `wait_for_network_idle/2` instead.

## Detect a 403 wall, a 404 or a login redirect

`navigate/3` returns `{:ok, page}` even for a 403 or a redirect-to-login. Pass
`response: true` to also get the main document's HTTP status and final (post-redirect)
URL:

```elixir
case CDPEx.Page.navigate(page, url, response: true) do
  {:ok, _page, %{status: 200, url: final_url}} -> {:landed, final_url}
  {:ok, _page, %{status: status}}              -> {:blocked, status}
  {:error, reason}                             -> {:error, reason}
end
```

## Authenticated proxy

Pass `:proxy` — CDPEx sets `--proxy-server` and answers the proxy's auth challenge on
each page automatically, so you just navigate:

```elixir
{:ok, browser} = CDPEx.launch(proxy: "http://user:pass@proxy.example.com:8080")
# keyword form avoids percent-encoding a special-char password:
# CDPEx.launch(proxy: [server: "proxy.example.com:8080", username: "u", password: "p@ss"])

CDPEx.with_page(browser, fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
```

This works for `:dedicated` and `:session` pages, so also on a `pipe: true`
browser. For a one-off HTTP Basic challenge on an *origin* (not a proxy), arm it per
page with `authenticate/4` before navigating:
`CDPEx.Page.authenticate(page, "user", "pass", source: :server)`.

To save proxy traffic, block the resource types you don't need. The library fails
those requests before they reach the proxy and answers the proxy's login for the
rest, so no process of yours has to handle them:

```elixir
{:ok, page} = CDPEx.new_page(browser, block: [:image, :font, :media])
{:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
```

`block:` is also accepted by `CDPEx.with_page/3` and `CDPEx.Pool.with_page/3`;
`CDPEx.Page.block_resources/3` changes the list on an open page. For a rule by URL
rather than by type, use `enable_request_interception/2` from a process that
resolves each pause, since the caller is busy in `navigate/3` while they arrive.
Requests from a cross-site iframe are not blocked: Chrome runs it as a separate
target (see `docs/TODO.md` item 13).

## Keep jobs apart on a shared browser

`isolated: true` opens a page in its own browser context: its own cookies,
`localStorage` and cache, disposed when the page closes, however it closes.
`CDPEx.Pool.with_page/3` does this by default; pass it yourself to a page you open
on a browser from `CDPEx.Pool.with_browser/3`, `checkout/2` or `launch/1`:

```elixir
CDPEx.Pool.with_browser(MyPool, fn browser ->
  CDPEx.with_page(browser, fn page ->
    {:ok, _} = CDPEx.Page.navigate(page, "https://example.com/login")
    CDPEx.Page.cookies(page)  # this page's context only
  end, isolated: true)
end)
```

Opening and closing an isolated page costs about 70–120 ms more than a plain one.
