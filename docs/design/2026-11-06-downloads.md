# Design: downloads

**Status:** done
**Tracks:** `docs/TODO.md` item 14

## Problem

CDPEx had no API for downloads: a scraper that clicks "Export CSV" had to drive
`Browser.setDownloadBehavior` and the `Browser.download*` events through
`CDPEx.Connection` itself. Worse, a launched Chrome kept its own default: every
download, awaited or not, was saved to the user's `~/Downloads`. On a server that
is a directory nobody cleans, outside the temp profile CDPEx removes.

## What Chrome does

Measured on Google Chrome 157 (macOS arm64, Linux amd64) and Chrome for Testing
156 (Linux arm64):

- `Browser.setDownloadBehavior` is per browser context. Without
  `browserContextId` it sets the default context; a context made by
  `Target.createBrowserContext` starts with Chrome's default and needs its own
  call.
- The last call for a context wins, whichever session sent it. When the session
  that sent it closes, the context goes back to the default (`~/Downloads`). So
  it has to be sent on the browser connection, which lives as long as the browser,
  not on a page's session.
- With `eventsEnabled: true`, `Browser.downloadWillBegin` (`frameId`, `guid`,
  `url`, `suggestedFilename`) and `Browser.downloadProgress` (`guid`, `state`,
  `receivedBytes`, and `filePath` once `completed`) arrive on the session that
  set it. On the browser connection that is every download in the context.
- `behavior: "allowAndName"` saves the file as `<downloadPath>/<guid>`, so two
  downloads with the same suggested name never collide.
- The deprecated `Page.downloadWillBegin` / `Page.downloadProgress` come on the
  page's session for the page and its same-process iframes only: a download from
  a cross-site iframe shows up only in the `Browser.*` events, with the iframe's
  frame id. They are not used.
- A cross-site iframe's frame id is not in the page's `Page.getFrameTree`. It is
  the iframe's target id, and `Target.getTargetInfo` on it gives `parentId`, the
  parent's target id.
- `Page.navigate` to a URL that turns into a download returns
  `net::ERR_ABORTED`, usually before `Browser.downloadWillBegin` arrives.
- `Browser.cancelDownload` on a download in progress deletes its partial file;
  Chrome reports `state: "canceled"`. A server that closes the connection
  mid-file is reported the same way, with no reason.

## Decisions

- **Every launched browser saves downloads in its profile dir.** At launch the
  browser sets `allowAndName` into `<user_data_dir>/cdp_ex-downloads` on the
  default context, and on each context it creates for `isolated: true`. A temp
  profile's removal takes the files with it. With a caller's own
  `:user_data_dir` the files stay there. If the call fails, the launch (or the
  isolated page) fails: falling back to `~/Downloads` silently is what this
  fixes.
- **Connect-mode is left alone.** Its Chrome writes on its own host under its own
  settings, and a path there means nothing locally. `wait_for_download/2` returns
  `{:error, {:unsupported_with_connect, :downloads}}`.
- **One call, `Page.wait_for_download/2`,** shaped like `wait_for_response/3`:
  `:trigger` runs in the caller after the wait is registered, `:timeout` bounds
  the whole download, `:path` moves the finished file (rename, or copy and delete
  across file systems). It returns `%{path, suggested_filename, url, size}`.
  Without `:path` the file stays in the profile dir until the browser stops.
- **The page's download is told apart by frame.** The frame id is the page's
  target id, or in its frame tree, or an iframe target whose `parentId` chain
  (up to 8 levels) reaches the page. A same-process frame inside a cross-site
  iframe is in that iframe's frame tree only and isn't matched: rare, and
  searching every iframe's tree on every download isn't worth it.
- **A helper process owns the wait.** It subscribes on the browser connection,
  so the caller's mailbox and subscriptions are untouched, and the subscription
  dies with it. It cancels a download in progress when the wait ends without it:
  timeout, a failed or raising trigger, or the caller's death.
- **A trigger's `{:error, _}` ends the wait unless the download already
  started.** Navigating to a file URL errors before the download is reported, so
  the docs show ignoring that result in the trigger.
- **New error reasons:** `{:download_canceled, url}` (`:unknown`: a dropped
  connection may clear, a full disk won't) and `{:download_wait_failed, reason}`
  for a helper crash (`:transient`, like `{:idle_wait_failed, _}`).
  `{:timeout, :wait_for_download}` joins the `{:timeout, _}` contexts for the
  Browser hop.

## Not done

- Reading a download into memory: `File.read/1` on the returned path.
- Several downloads from one trigger: the first one of the page is returned.
- Deleting unclaimed files during a long-lived browser's life. They go with the
  profile when the browser stops.
