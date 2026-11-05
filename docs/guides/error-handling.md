# Error handling

Operations return `{:error, reason}` on failure, runtime failures included: Chrome
that can't be spawned, a browser, page or pool that is gone or dies mid-call, a call
that can't be served in time. None of them raises or exits in your process, so
`with_page/3` needs no `rescue`/`catch :exit` around it. Invalid arguments still
raise, and so does anything your own `with_page` function raises, throws or exits
with.

That covers return values, not links. A browser started with `CDPEx.launch/1` or
`CDPEx.connect/2` is linked to the process that started it (the link is what reaps
Chrome when that process dies), so if the browser stops on its own, for example
because Chrome died, the exit signal still reaches a starter that doesn't trap exits.
Run a long-lived browser under your own supervisor. `with_page/3` with launch options
contains this for its throwaway browser.

Rather than hard-code the reason shapes, classify them to drive retries:

```elixir
case CDPEx.Page.navigate(page, url) do
  {:ok, page} ->
    {:ok, page}

  {:error, reason} ->
    if CDPEx.transient?(reason), do: retry(), else: {:error, reason}
end
```

`CDPEx.classify_error/1` buckets a reason as `:transient` (connection dropped or
couldn't be established, the page closed, timeout, Chrome died or was slow to start, an internal helper
crashed, or a connection-layer `net::ERR_*` navigation error, so a fresh attempt may
succeed), `:terminal` (selector miss, JS exception, usage/validation error, which a
retry won't fix), or `:unknown` (payload-dependent, e.g. an ambiguous `net::ERR_*`
navigation error or a CDP error code; you decide). The library tracks the error surface, so the
transient/terminal decision lives in one place instead of drifting across callers.
The reason shapes are documented as `t:CDPEx.error_reason/0`
([`lib/cdp_ex.ex`](../../lib/cdp_ex.ex)).

Retries are yours to bound: cap attempts, back off, and on a `:transient` result
re-establish the resource (open a fresh page/browser) rather than reusing a dead
handle — a dead page keeps returning `:noproc`, or `{:session_closed, session_id}` for a
`:session` page (the default on a `connect/2` or `pipe: true` browser).
