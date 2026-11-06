# Design: Fetch modes inside cross-site iframes

**Status:** done
**Tracks:** `docs/TODO.md` item 13

## Problem

Chrome runs a cross-site iframe (an out-of-process iframe, OOPIF) as its own
`iframe` target with its own `Fetch` domain. `CDPEx.Fetch` drives only the page
target's, so on such an iframe:

- `block:` doesn't block (an image in a `localhost` iframe on a `127.0.0.1` page
  reached the server with `block: [:image]`, Chrome 156; pinned by the integration
  test "a cross-site iframe's requests are not blocked (known gap)");
- request interception doesn't see its requests;
- the proxy login works today only because Chrome reuses the credentials the page
  target already gave the proxy; a fresh challenge on the iframe's requests would
  go unanswered.

Ad and embed iframes are where much of a page's image and media bytes come from,
so this is where `block:` saves the most proxy traffic.

## What a spike showed (2026-11-06, Google Chrome 156, macOS)

On both transports (`:dedicated`, and `:session` over the browser socket):

1. `Target.setAutoAttach` on the page's session with `autoAttach: true`,
   `waitForDebuggerOnStart: true`, `flatten: true` and
   `filter: [%{"type" => "iframe"}]` makes Chrome send `Target.attachedToTarget`
   for the OOPIF, on the page's session, with the child's `sessionId`.
2. The child is paused before it runs. `Fetch.enable` on the child session, then
   `Runtime.runIfWaitingForDebugger`, filters every request the iframe's own
   renderer makes: its `pixel.png` paused on the child session and was failed.
3. The iframe's document request itself was served before the attach (it is the
   parent frame's navigation), so it is outside the child's `Fetch` domain.

## Goals

- `block:` and the proxy / HTTP login apply inside cross-site iframes, nested ones
  included, on both transports.
- No iframe is left paused: every attached child is resumed on every path
  (success, a failed `Fetch.enable`, an owner crash).
- A page with no `Fetch` mode on pays nothing: auto-attach is only turned on when a
  mode is.

## Non-goals (for this design)

- Request interception inside iframes: the owner continues an iframe's pauses, and
  the docs say interception covers the page's own frames only (decided 2026-11-06,
  option 1 below; option 2 if someone needs it).
- Workers and service workers (also targets): the filter attaches iframes only, so
  workers are never paused.
- Same-site iframes: they share the page's renderer and are already covered.

## Design

### One owner, several sessions

`CDPEx.Fetch` stays the single owner per page. Its state gains `children`: a map
from child session id to its per-session bookkeeping (`subscribed`, `attempts`).
The page's own session is the root.

- When the first mode is armed, the owner sends `Target.setAutoAttach` (as above)
  on the root session, subscribed to `Target.attachedToTarget` and
  `Target.detachedFromTarget` for it.
- On `Target.attachedToTarget` with `targetInfo.type == "iframe"`: subscribe the
  child's `Fetch.requestPaused` / `Fetch.authRequired`, send `Target.setAutoAttach`
  on the child (nested OOPIFs), send `Fetch.enable` with the page's current params,
  then `Runtime.runIfWaitingForDebugger`. The resume runs even when an earlier step
  failed (the iframe then loads unfiltered; logged once).
- `rearm/3` applies a mode change to the root and every child. A child whose
  enable fails keeps its previous params; the reply reflects the root's result.
- On `Target.detachedFromTarget` for a child: drop it. When the page ends, the
  children go with it, nothing to disable.

### Deciding a pause

`decide/2` is unchanged and runs per session: block and auth answer on the
session the pause or challenge came from (`Fetch.failRequest`,
`Fetch.continueRequest`, `Fetch.continueWithAuth` with that `session_id`). With
interception on, a child's pause is continued (see "Open question").

### Turning it off

When every mode is off the owner sends `Fetch.disable` on the root and each
child, and `Target.setAutoAttach` with `autoAttach: false` on the root, so later
iframes start unpaused.

## Risks

- **A stuck iframe.** `waitForDebuggerOnStart` holds every new OOPIF until the
  owner resumes it. The owner resumes on every path for that child. An owner that
  crashes between an attach and its resume would leave that iframe waiting;
  unverified whether Chrome resumes it on its own when the auto-attach is dropped.
  The integration tests must check this before the design is called done.
- **Cost with auth on.** Every request of every iframe round-trips through the
  owner, as on the page today.
- **Another client auto-attaching** on the same page (a caller sending
  `Target.setAutoAttach` itself) would see its own attaches; the owner only reacts
  to iframe attaches on its page's session.

## Decided: no request interception inside iframes

**Request interception inside iframes.** A child's pause has to be resolved on the
child's session, but `continue_request/3`, `fulfill_request/3` and
`fail_request/3` take only the request id and send on the page's session. Options:

1. Leave it out: the owner continues children's pauses, and the docs say
   interception covers the page's own frames only. Smallest change.
2. Forward children's pauses too, and route the three resolve calls through the
   Fetch owner, which knows each forwarded id's session. The caller's code doesn't
   change, but every resolve becomes a Browser/owner hop.
3. Forward them with the child's session id in the event tuple, and add an
   optional `session_id:` to the resolve calls. Cheap, but the caller must thread
   the id through.

Chosen: 1. Option 2 stays open for when someone needs it.

## Tests

Unit (`FakeCDP`): attach → subscribe, nested auto-attach, enable with current
params, resume, in that order; resume after a failed enable; rearm reaches every
child; detach drops a child; block and auth answered on the child's session;
auto-attach off when the last mode goes.

Integration (real Chrome, `localhost` iframe on a `127.0.0.1` page):
`block: [:image]` blocks the iframe's image on `:dedicated` and `pipe: true`;
a nested OOPIF; a credentialed proxy still loads the iframe; `block_resources(page,
[])` lets later iframes load unpaused; closing the page mid-attach leaves no Chrome
behind. The "known gap" test flips.
