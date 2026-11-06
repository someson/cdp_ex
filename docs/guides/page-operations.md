# Page operations

| Function | Description |
|---|---|
| `navigate/3` | Go to a URL, waiting for `networkAlmostIdle` (configurable); `response: true` adds the document's status, final URL, headers and request id |
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
| `hover/3` | Move a trusted pointer over the first match (`mouseover`, CSS `:hover`), hit-tested like `click/3` |
| `type/4` | Focus an element and enter text (`Input.insertText`) |
| `press/4` | Press a named key — `Enter`, `Tab`, arrows, … — with real key events |
| `set_input_files/4` | Set the files of an `<input type="file">`; `[]` clears it |
| `scroll/3` | Scroll the window to `:top`, `:bottom`, or `{x, y}` |
| `frame/3` | A handle for an `<iframe>`'s frame, same-site or cross-site, that the element and script functions above accept in place of the page |
| `set_dialogs/3` / `handle_dialog/3` | How `alert`/`confirm`/`prompt`/`beforeunload` are answered (`:accept` by default, also `dialogs:` on `new_page/2`), or answer one by hand under `:manual` |
| `html/2` | Full serialized DOM (`document.documentElement.outerHTML`) |
| `screenshot/2` | PNG bytes, or write to `:path` |
| `pdf/2` | Render the page to PDF bytes, or write to `:path` |
| `set_user_agent/3` | Override the UA string, with optional Client-Hints metadata + `Accept-Language` |
| `set_extra_headers/3` | Extra HTTP headers on every later request from the page |
| `set_viewport/4` | Override the viewport size (and device scale factor) |
| `cookies/2` / `set_cookies/3` / `clear_cookies/2` | Read, set, or clear the cookies of the page's browser context (browser-wide for a page that isn't isolated) |
| `observe_network/2` / `stop_observing_network/2` | Stream `Network` request/response events to the caller, or stop |
| `response_body/3` | Fetch a response body by requestId (`Network.getResponseBody`) |
| `enable_request_interception/2` / `disable_request_interception/2` | Pause matching requests for the caller to resolve, or stop; combines with `authenticate/4` and a credentialed `:proxy` |
| `continue_request/3` / `fulfill_request/3` / `fail_request/3` | Resolve a paused request (proceed / synthetic response / fail) |
| `authenticate/4` | Answer a proxy / HTTP Basic auth challenge (call before `navigate/3`) |
| `block_resources/3` | Fail requests of the given resource types (`:image`, `:font`, ...) before they reach the network; `[]` stops. Also `block:` on `new_page/2` |

## Inside an iframe

```elixir
{:ok, frame} = CDPEx.Page.frame(page, "iframe#checkout", wait: 5_000)
{:ok, price} = CDPEx.Page.text(frame, ".total")
:ok = CDPEx.Page.click(frame, "button[type=submit]")
```

A frame handle reads, runs script and acts inside the frame: `evaluate/3`,
`text/3`, the waits on selectors and functions, `click/3`, `hover/3`, `type/4`,
`press/4`, `set_input_files/4`. Cross-site frames, which Chrome runs in their own
process, work the same way; mouse events still go to the page, shifted to the
frame, and fail with `:obscured` when something covers the `<iframe>`. Pass a frame
handle to `frame/3` for a nested one. Navigation, screenshots, cookies, network and
other page-wide functions take the page itself.

Every function is documented in full in `CDPEx.Page`; `mix docs` builds the docs.
Recipes that combine them: [recipes.md](recipes.md).
