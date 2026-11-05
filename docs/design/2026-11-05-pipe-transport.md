# Design: pipe transport

**Status:** implemented
**Tracks:** `docs/TODO.md` item 3

## Problem

A launched Chrome listens for DevTools on a local TCP port
(`--remote-debugging-port=0`). Any process on the host that finds the port can
drive the browser, including its cookies and logged-in sessions. CDPEx then
waits for the `DevTools listening on` stderr line (or polls
`DevToolsActivePort`) and opens a WebSocket.

The TODO entry assumed that this wait accounted for most of the cold-start gap
to Playwright (532 vs 458 ms at p50), since Playwright uses
`--remote-debugging-pipe`.

## Evidence

Probed before writing the transport. From `Port.open` to the reply to the first
CDP command (`Browser.getVersion`), medians of 10 after one warm-up launch:

| Host | WebSocket | Pipe |
|------|-----------|------|
| Ubuntu 26.04 container, Chromium (Playwright 1.64.1) arm64, 4 CPUs | 120 ms | 104 ms |
| macOS, Google Chrome stable | ~410 ms | ~410 ms |

A full cycle on the same Linux container, `launch → new_page → stop` (the
navigation is left out because it doesn't depend on the transport): launch
105 ms, page 70 ms, stop 51 ms. The pipe saves about 15 ms of ~225, about 7%.
The stderr line arrives promptly, so the 150 ms poll is not on the hot path.
The rest of the gap to Playwright is elsewhere.

Chrome exits by itself when its end of the pipe closes: 75–100 ms after
`Port.close/1` on Linux, 140–270 ms on macOS.

## Decision

An opt-in launch option, `pipe: true`, default `false`. The case for it is
mainly that no TCP port is opened; the speed gain is a side effect.

## Design

- **Launch** (`CDPEx.Chrome`). `--remote-debugging-pipe` replaces
  `--remote-debugging-port=0`. Chrome reads CDP on fd 3 and writes on fd 4; a
  Port gives only stdin and stdout, so Chrome runs under
  `exec "$0" "$@" 3<&0 4>&1 0</dev/null 1>/dev/null 2>/dev/null`. Chrome's
  stdout and stderr go to `/dev/null`, since anything else on the Port's
  stdout would corrupt the CDP stream. Readiness: write a `Browser.getVersion`
  probe (id 0) and wait for its reply, bounded by `:launch_timeout`. A timeout or
  an unexpected reply is `{:debug_url_not_found, excerpt}`; an exit before the
  reply goes through the existing `exit_reason/2`. The error taxonomy is
  unchanged.
- **Framing** (`CDPEx.Protocol.split_pipe_messages/2`). NUL-delimited JSON.
  Only the new chunk is scanned, so an 8 MB message arriving in many chunks
  costs linear time.
- **Connection.** `Connection.start_link({:pipe, port})`. The Browser, which
  opened the Port inside `Chrome.launch/1`, moves it to the connection with
  `Port.connect/2`. The connection must own the Port: the Browser blocks inside
  `new_page` on `Connection.call`, so it couldn't forward replies to itself.
  `Port.connect/2` also links the connection to the Port. Chrome's exit status
  stops the connection with `{:ws_closed, {:chrome_exited, status}}`, and the
  Browser turns that into `{:chrome_exited, status}`, as for a WebSocket browser.
  The connection's exit closes the Port.
- **Pages.** No endpoint exists for a per-page socket, so a pipe browser behaves
  like a connected one: pages default to `:session`, and `:dedicated` returns
  `{:error, {:unsupported_transport, :dedicated}}`. A `:proxy` with credentials
  first failed the launch with `{:invalid_proxy, :pipe}`, since proxy auth needed
  `:dedicated` pages; since #17 it is answered on `:session` pages too.

## Reaping

The `/bin/sh` watchdog (#2) reads the Port's stdin to notice the VM exiting. In
pipe mode stdin carries CDP, so the watchdog can't run. Chrome's own exit on
pipe EOF takes its place: the OS closes the pipe however the VM exits. The
integration test that halts a child VM covers both modes. Inside a running VM,
`stop/1` still kills Chrome with `kill -9` and removes the profile dir, as
before.

Not covered: a Chrome wedged so badly that it doesn't act on EOF, when the VM
also dies without running `terminate/2`. The watchdog would have killed it.

## Not done

- `:dedicated` pages over a pipe browser (they would need a TCP port again).
- Windows: there is no `/bin/sh` to remap the fds; `pipe: true` raises
  `ArgumentError`.
- Keeping Chrome's stderr in pipe mode, for example in a file in the profile dir.
