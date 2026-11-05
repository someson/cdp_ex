# Process labels

Every GenServer and task CDPEx starts sets a [process
label](https://hexdocs.pm/elixir/Process.html#set_label/1), so crash reports,
`:observer`, and Phoenix LiveDashboard name it instead of showing a bare pid.
Nothing to configure; labels are set on Elixir 1.17+ and read by OTP 27+. (The
`Task.Supervisor` backing `CDPEx.Pool`'s launches is the one exception — OTP
offers no way to label a supervisor from outside it.)

| Label | Process |
|-------|---------|
| `{:cdp_browser, os_pid}` | `CDPEx.Browser` — `os_pid` is the Chrome process it launched (`:starting` until Chrome is up, `:connected` in connect-mode, `:launched` if the OS pid could not be read) |
| `{:cdp_connection, "/devtools/browser/…"}` | the browser WebSocket |
| `{:cdp_connection, "/devtools/page/<targetId>"}` | a `:dedicated` page WebSocket |
| `{:cdp_connection, :pipe}` | the browser connection of a `pipe: true` browser |
| `{:cdp_page_helper, :idle_wait \| :capture, target_id}` | the short-lived process behind `wait_for_network_idle/2` and `navigate/3` with `response: true` |
| `{:cdp_page_helper, :detach_watch, target_id}` | the short-lived process that watches a `:session` page's detach during `navigate/3` and `wait_for_navigation/2` |
| `{:cdp_authenticate, target_id}` | the short-lived relay behind `Page.authenticate/4` |
| `{:cdp_fetch, target_id}` | the page's `Fetch` owner: answers login challenges and forwards intercepted requests |
| `{:cdp_context_dispose, context_id}` | the throwaway task that disposes an isolated page's context after the page went away on its own |
| `{:cdp_pool, size}` / `{:cdp_pool_launch, pool}` | `CDPEx.Pool` and its browser-launch tasks |
| `{:cdp_deadline, ms}` | the watchdog behind `with_page/3`'s `:deadline` |

The page-helper label is the one to reach for when a scrape appears hung: it
names the target that is still waiting, and the browser label's `os_pid` ties a
suspect BEAM process to a row in `ps`.

Connection labels carry the DevTools path without its query string: the target
can hold an auth token for a remote endpoint, and labels are read far more
widely than internal state.
