defmodule CDPEx.Page do
  @moduledoc """
  A page (tab) handle and the operations you run against it.

  A `CDPEx.Page` is a lightweight struct — not a process — holding the page's
  `CDPEx.Connection` pid and target id. Operations are functions over that
  connection, so the OTP properties (supervision, crash isolation) live in the
  connection/browser layer while page calls stay ergonomic.

  Obtain one with `CDPEx.new_page/2`. If the underlying page dies (navigation to
  a new target, a crash), operations return `{:error, :noproc}` and you should
  open a fresh page. On a `:session` page, whose connection is the shared browser
  socket and outlives it, a closed or detached target returns
  `{:error, {:session_closed, session_id}}` instead.

  ## Operations

    * **Navigation** — `navigate/3`, `wait_for_navigation/2`
    * **Evaluation** — `evaluate/3`, `call_function/4`, `html/2`
    * **Waiting** — `wait_for_selector/3`, `wait_for_function/3`
    * **Elements** — `text/3`, `attribute/4`, `visible?/3`, `click/3`, `click_text/3`, `type/4`, `press/4`
    * **Scrolling** — `scroll/3`
    * **Capture** — `screenshot/2`, `pdf/2`
    * **Emulation** — `set_viewport/4`, `set_user_agent/3`
    * **Cookies & headers** — `cookies/2`, `set_cookies/3`, `clear_cookies/2`, `set_extra_headers/3`
    * **Network** — `observe_network/2`, `stop_observing_network/2`, `response_body/3`
    * **Downloads** — `wait_for_download/2`
    * **Console** — `observe_console/2`, `stop_observing_console/2`
    * **Interception** — `enable_request_interception/2`, `disable_request_interception/2`, `continue_request/3`, `fulfill_request/3`, `fail_request/3`
    * **Auth** — `authenticate/4` (proxy / HTTP Basic challenges)
  """

  alias CDPEx.Browser
  alias CDPEx.Connection
  alias CDPEx.Fetch
  alias CDPEx.ProcessLabel
  alias CDPEx.Protocol
  alias CDPEx.Telemetry

  require Logger

  @navigate_timeout 30_000
  @evaluate_timeout 15_000
  @selector_timeout 5_000
  # The longest delay a browser timer holds: setTimeout/setInterval treat anything
  # above 2^31 - 1 ms as 0, so a larger wait :timeout would fire at once and a larger
  # :interval would poll every few ms.
  @max_timer_ms 2_147_483_647
  # Extra time the CDP call for an in-page wait gets past the wait's own timeout,
  # so the page's timer normally settles it; see await_truthy/4.
  @wait_grace 500
  @screenshot_timeout 30_000
  @command_timeout 10_000
  @click_poll_interval 100
  @files_object_group "cdp_ex-set-input-files"
  @probe_timeout 2_000
  @retryable_locate [:selector_not_found, :text_not_found, :not_clickable, :obscured]
  # All -32000: a context that never existed (the script didn't run) vs one torn down mid-call.
  @context_not_found ["Cannot find context", "Cannot find default execution context"]
  @context_torn_down ["Execution context was destroyed", "Inspected target navigated or closed"]
  @context_missing @context_not_found ++ @context_torn_down
  # Slack past a capture/wait helper's own deadline before run_in_helper/4 force-kills it.
  # The helper bounds every op by the deadline, so it returns on its own well within this;
  # the grace is a last-resort net (generous, to never pre-empt a merely-slow helper under
  # the scheduler starvation these deadlines guard against).
  @helper_grace 5_000

  # Named keys supported by press/4, with the CDP fields Input.dispatchKeyEvent
  # needs for default actions to fire (Enter submits, Tab moves focus, etc.).
  @keymap %{
    # `text: "\r"` is required for Enter's default action (implicit form submit) to
    # fire under Input.dispatchKeyEvent; a bare keyDown is treated as a raw key.
    "Enter" => %{"key" => "Enter", "code" => "Enter", "windowsVirtualKeyCode" => 13, "text" => "\r"},
    "Tab" => %{"key" => "Tab", "code" => "Tab", "windowsVirtualKeyCode" => 9},
    "Escape" => %{"key" => "Escape", "code" => "Escape", "windowsVirtualKeyCode" => 27},
    "Backspace" => %{"key" => "Backspace", "code" => "Backspace", "windowsVirtualKeyCode" => 8},
    "Delete" => %{"key" => "Delete", "code" => "Delete", "windowsVirtualKeyCode" => 46},
    "ArrowUp" => %{"key" => "ArrowUp", "code" => "ArrowUp", "windowsVirtualKeyCode" => 38},
    "ArrowDown" => %{"key" => "ArrowDown", "code" => "ArrowDown", "windowsVirtualKeyCode" => 40},
    "ArrowLeft" => %{"key" => "ArrowLeft", "code" => "ArrowLeft", "windowsVirtualKeyCode" => 37},
    "ArrowRight" => %{"key" => "ArrowRight", "code" => "ArrowRight", "windowsVirtualKeyCode" => 39},
    "Home" => %{"key" => "Home", "code" => "Home", "windowsVirtualKeyCode" => 36},
    "End" => %{"key" => "End", "code" => "End", "windowsVirtualKeyCode" => 35}
  }

  @lifecycle_method "Page.lifecycleEvent"
  @target_detached "Target.detachedFromTarget"
  @request_will_be_sent "Network.requestWillBeSent"
  @response_received "Network.responseReceived"
  @loading_finished "Network.loadingFinished"
  @loading_failed "Network.loadingFailed"
  @network_events [@request_will_be_sent, @response_received]
  @console_events ["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]
  # In-flight accounting for wait_for_network_idle/2: requestWillBeSent (+1),
  # loadingFinished / loadingFailed (−1). responseReceived is deliberately excluded.
  @idle_events [@request_will_be_sent, @loading_finished, @loading_failed]
  @download_will_begin "Browser.downloadWillBegin"
  @download_progress "Browser.downloadProgress"
  @download_events [@download_will_begin, @download_progress]
  # How many cross-site iframes deep download_owner?/4 follows a frame back to its page.
  @max_iframe_depth 8

  @enforce_keys [:browser, :conn, :target_id]
  defstruct [:browser, :conn, :target_id, :session_id, :frame]

  @typedoc """
  A page handle, or a frame handle from `frame/3` (`frame` set). A frame handle's
  other fields are its page's; where the frame's script runs is looked up on each
  call.
  """
  @type t :: %__MODULE__{
          browser: pid(),
          conn: pid(),
          target_id: String.t(),
          session_id: String.t() | nil,
          frame: frame() | nil
        }

  # id: the frame's id (an out-of-process frame's target id too); label: the css
  # that found it, for errors; owner: the backendNodeId of its <iframe> in `parent`.
  @typep frame :: %{id: String.t(), label: String.t(), parent: t(), owner: integer()}

  @typedoc "A finished download, from `wait_for_download/2`."
  @type download :: %{
          path: String.t(),
          suggested_filename: String.t() | nil,
          url: String.t() | nil,
          size: non_neg_integer() | nil
        }

  @doc """
  Navigates to `url` and (by default) waits until the network is almost idle.

  Returns `{:ok, page}` so it pipelines with `with`. The readiness wait is
  best-effort: if it times out, navigation still returns `{:ok, page}` (the page
  may simply be slow); a hard navigation error returns `{:error, _}`. The milestone
  is matched to *this* navigation's document (by `loaderId`) — or to a document that
  replaces it before it settles, such as a `<meta http-equiv="refresh">` target — so a
  late lifecycle event from the page's previous document (e.g. the `about:blank` a
  fresh page starts on) can't end the wait early, and a client-side redirect doesn't
  stall it until the deadline.

  ## Capturing the document response

  Pass `response: true` to also get the main document's HTTP outcome — a clean signal
  for "did I land on the real page", versus a 403 wall / 404 / redirect-to-login that
  all otherwise look like success:

      {:ok, page, %{status: 200, url: final_url, headers: headers, request_id: id}} =
        Page.navigate(page, url, response: true)

  `status` is the HTTP status and `url` is the **final** URL after redirects,
  correlated to *this* navigation's main document by its `loaderId` (not "the first
  `Document` response seen"). `headers` are the final response's headers as Chrome
  reports them (names as sent; a repeated header such as `Set-Cookie` joined with
  `"\n"`), `%{}` when Chrome gave none. `request_id` reads the document's body with
  `response_body/3`: after a `:load` or `:network_almost_idle` wait the document has
  finished loading; with `wait_until: :none` the body may not have arrived yet. This lazily enables the `Network` domain (and leaves it
  enabled). If no main document response arrives before the wait ends, it returns
  `{:error, {:no_document_response, url}}` (e.g. a same-document/hash navigation that
  loads no new document, or a connection that never produced an HTTP response — though
  the latter usually surfaces earlier as `{:navigate, _}`).

  `response: true` captures the document response in a short-lived helper process with
  its own `Network.responseReceived` subscription, so it composes safely with
  `observe_network/2` on the same page — the caller's subscription and any buffered
  events are left untouched. A normal connection drop still surfaces as
  `{:error, :noproc}` / `{:error, {:ws_closed, _}}` (a `:session` page's detach as
  `{:error, {:session_closed, sid}}`); only an abnormal crash of that
  internal helper returns `{:error, {:capture_failed, reason}}`.

  Options:
    * `:wait_until` — `:network_almost_idle` (default), `:load`, or `:none`
    * `:response` — `true` to also return `%{status, url, headers, request_id}`
      (default `false`)
    * `:timeout` — overall ceiling in ms (default 30_000); spans the lazy `Network.enable`,
      the event subscription, the navigation, and the readiness/capture wait
  """
  @spec navigate(t(), String.t(), keyword()) ::
          {:ok, t()}
          | {:ok, t(),
             %{
               status: non_neg_integer(),
               url: String.t(),
               headers: %{optional(String.t()) => String.t()},
               request_id: String.t() | nil
             }}
          | {:error, term()}
  def navigate(%__MODULE__{frame: nil} = page, url, opts \\ []) do
    Telemetry.span(:navigate, %{url: url}, fn ->
      result = do_navigate(page, url, opts)
      {result, navigate_metadata(url, result)}
    end)
  end

  defp do_navigate(page, url, opts) do
    timeout = Keyword.get(opts, :timeout, @navigate_timeout)
    wait_until = Keyword.get(opts, :wait_until, :network_almost_idle)

    if Keyword.get(opts, :response, false) do
      navigate_capturing_response(page, url, wait_until, timeout)
    else
      navigate_with_wait(page, url, wait_until, timeout)
    end
  end

  # Span :stop metadata for navigate/3: status + final_url are populated only on the
  # response:true 3-tuple; an error tuple flows through :stop with :error set.
  defp navigate_metadata(url, {:ok, _page, resp}),
    do: %{url: url, status: resp.status, final_url: resp.url}

  defp navigate_metadata(url, {:ok, _page}), do: %{url: url, status: nil, final_url: nil}

  defp navigate_metadata(url, {:error, reason}),
    do: %{url: url, status: nil, final_url: nil, error: reason}

  # `:none` is a single Page.navigate call with no subscribe/wait step, so there is no
  # multi-step budget to share — it uses the raw timeout directly (the other clauses thread
  # an absolute deadline because they span subscribe + navigate + wait).
  defp navigate_with_wait(page, url, :none, timeout) do
    case do_call(page, "Page.navigate", %{"url" => url}, timeout) do
      {:ok, %{"errorText" => error}} -> {:error, {:navigate, error}}
      {:ok, _result} -> {:ok, page}
      {:error, _} = error -> error
    end
  end

  defp navigate_with_wait(page, url, wait_until, timeout) do
    name = lifecycle_name(wait_until)
    deadline = System.monotonic_time(:millisecond) + timeout

    # Issue the navigate (after subscribing — see subscribe_then_await/4) and wait
    # for its lifecycle milestone. The readiness wait is best-effort: a timeout
    # still returns {:ok, page} (the page may just be slow); a dead connection does not.
    # One deadline spans subscribe + navigate + the wait, so :timeout is a true ceiling.
    trigger = fn ->
      case do_call(page, "Page.navigate", %{"url" => url}, remaining(deadline)) do
        {:ok, %{"errorText" => error}} -> {:error, {:navigate, error}}
        {:ok, result} -> {:ok, result["loaderId"], result["frameId"]}
        {:error, _} = error -> error
      end
    end

    case subscribe_then_await(page, name, deadline, trigger) do
      :reached ->
        {:ok, page}

      :timeout ->
        Logger.debug("[CDPEx.Page] readiness wait (#{name}) timed out; returning best-effort")
        {:ok, page}

      {:down, reason} ->
        {:error, down_reason(reason)}

      {:error, _} = error ->
        error
    end
  end

  # Like navigate_with_wait/4 but also captures the main-document Network.responseReceived
  # (HTTP status + final URL) for THIS navigation. Kept separate so the default path
  # stays untouched. Requires the Network domain; enables it lazily. The capture itself
  # runs in an isolated helper process (run_in_helper/4) so it never disturbs a
  # same-process observe_network/2 subscription (#42).
  defp navigate_capturing_response(page, url, wait_until, timeout) do
    # Validate :wait_until up front (lifecycle_name/1 raises on a bad value) so an
    # invalid option never enables Network / spawns the helper first — matching the
    # default path, which validates before any side effect.
    milestone = if wait_until == :none, do: nil, else: lifecycle_name(wait_until)
    deadline = System.monotonic_time(:millisecond) + timeout

    # One deadline spans enable + subscribe + navigate + the capture wait, so :timeout is a
    # true overall ceiling (mirrors wait_for_response/3 and wait_for_network_idle/2).
    with :ok <- ensure_network(page, remaining(deadline)) do
      run_in_helper(
        fn -> run_capture(page, url, milestone, deadline) end,
        :capture_failed,
        deadline,
        {:cdp_page_helper, :capture, page.target_id}
      )
    end
  end

  # Run a capture/wait body (`fun`) in its own short-lived, monitored process and return
  # its result. The body subscribes to its CDP events on *the helper's* pid and drains
  # *the helper's* mailbox, so a caller that is also running observe_network/2 on this page
  # keeps its subscription and its buffered events intact (#42, #48). Connection monitors
  # every subscriber and drops it on :DOWN, so the helper's subscriptions are released when
  # it exits — no explicit unsubscribe. `fun` must bound every blocking op it makes against
  # `deadline` (subscribe_each + the CDP calls carry `remaining(deadline)`; the await loops
  # monitor the conn and honour `deadline`), so it returns on its own within the budget;
  # `after remaining(deadline) + @helper_grace` is a last-resort net that force-kills a body
  # that ignores the deadline, so the caller never blocks past the ceiling. A helper that
  # crashes before replying (a should-never-happen bug) surfaces as {:error, {on_crash, reason}}.
  defp run_in_helper(fun, on_crash, deadline, label) when is_function(fun, 0) do
    parent = self()
    tag = make_ref()

    {helper, mon} =
      spawn_monitor(fn ->
        ProcessLabel.set(label)
        send(parent, {tag, fun.()})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^helper, reason} ->
        {:error, {on_crash, reason}}
    after
      remaining(deadline) + @helper_grace ->
        # Prefer a result that just landed (the helper raced the ceiling). Otherwise kill the
        # wedged helper and drain any reply it sent right before dying, so a tagged message
        # can't linger in the caller's mailbox — demonitor [:flush] clears only the :DOWN.
        # Mirrors the deadline-vs-DOWN tie guards in await_lifecycle/await_capture.
        receive do
          {^tag, result} ->
            Process.demonitor(mon, [:flush])
            result
        after
          0 ->
            Process.exit(helper, :kill)
            Process.demonitor(mon, [:flush])

            receive do
              {^tag, _} -> :ok
            after
              0 -> :ok
            end

            {:error, {on_crash, :timeout}}
        end
    end
  end

  # The capture helper body (runs in the spawned process). Subscribes on its own pid (within
  # the shared deadline), then issues the navigation and accumulates the main-document
  # response. Returns capture_after_navigate/5's fully mapped result: {:ok, page, %{status,
  # url}} | {:error, reason}. No before/after drain is needed — the helper's mailbox starts
  # empty and dies with it.
  defp run_capture(page, url, milestone, deadline) do
    methods = watched(page, [@lifecycle_method, @response_received])

    case subscribe_each(page.conn, methods, remaining(deadline), page.session_id) do
      :ok ->
        ref = Process.monitor(page.conn)
        capture_after_navigate(page, url, milestone, ref, deadline)

      {:error, _} = error ->
        error
    end
  end

  defp capture_after_navigate(page, url, milestone, ref, deadline) do
    case do_call(page, "Page.navigate", %{"url" => url}, remaining(deadline)) do
      {:ok, %{"errorText" => error}} ->
        {:error, {:navigate, error}}

      {:ok, result} ->
        nav = navigation(result["loaderId"], result["frameId"])

        case await_capture(page, milestone, ref, deadline, nav, nil) do
          {:ok, nil} -> {:error, {:no_document_response, url}}
          {:ok, resp} -> {:ok, page, resp}
          {:down, reason} -> {:error, down_reason(reason)}
        end

      {:error, _} = error ->
        error
    end
  end

  # Await the readiness milestone (or, with :none, the document response itself) while
  # accumulating the main-document response — scoped to this page's session (`^sid`).
  # The response is correlated to THIS navigation's document (`nav.loader`, type
  # "Document"); the milestone follows track_lifecycle/2, so a successor document can
  # end the wait while %{status, url} still describes the document we navigated to.
  defp await_capture(
         %__MODULE__{conn: conn, session_id: sid} = page,
         milestone,
         ref,
         deadline,
         nav,
         captured
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:cdp_event, ^conn, @response_received, params, ^sid} ->
        captured =
          if document_response?(params, nav.loader, nav.frame),
            do: response_summary(params),
            else: captured

        if is_nil(milestone) and not is_nil(captured) do
          {:ok, captured}
        else
          await_capture(page, milestone, ref, deadline, nav, captured)
        end

      {:cdp_event, ^conn, @lifecycle_method, %{"name" => name} = params, ^sid}
      when not is_nil(milestone) ->
        case track_lifecycle(params, nav) do
          {:ours, _nav} when name == milestone -> {:ok, captured}
          {_, nav} -> await_capture(page, milestone, ref, deadline, nav, captured)
        end

      {:cdp_event, ^conn, @target_detached, %{"sessionId" => ^sid}, _parent} ->
        {:down, {:session_closed, sid}}

      {:cdp_event, ^conn, _method, _params, _other_sid} ->
        # Another session's event, or (with milestone nil) a lifecycle we don't wait on.
        await_capture(page, milestone, ref, deadline, nav, captured)

      {:DOWN, ^ref, :process, ^conn, reason} ->
        {:down, reason}
    after
      remaining ->
        # Best-effort: return whatever document response we captured (nil → the caller
        # maps it to {:error, {:no_document_response, _}}). Prefer a just-landed :DOWN
        # or detach.
        receive do
          {:DOWN, ^ref, :process, ^conn, reason} ->
            {:down, reason}

          {:cdp_event, ^conn, @target_detached, %{"sessionId" => ^sid}, _} ->
            {:down, {:session_closed, sid}}
        after
          0 -> {:ok, captured}
        end
    end
  end

  # The main document response for THIS navigation: type "Document", matching loaderId
  # (+ frameId when the navigate result carried one), and a well-formed response (an
  # integer status and a URL). Requiring both keeps the {:ok, page, %{status, url}}
  # contract honest — a degenerate response missing them is not reported as the landing,
  # so the call falls through to {:error, {:no_document_response, _}} rather than
  # returning nils. (Real Chrome always populates both on a Document response.)
  # Deliberately stricter than own_loader?/3: with no loaderId on the navigate result the
  # milestone still ends the wait promptly, but nothing is captured, so the call reports
  # {:error, {:no_document_response, _}} instead of guessing which response was ours.
  defp document_response?(
         %{
           "type" => "Document",
           "loaderId" => loader,
           "response" => %{"status" => status, "url" => url}
         } = params,
         lid,
         fid
       )
       when is_integer(status) and is_binary(url) do
    loader == lid and Map.get(params, "frameId", fid) == fid
  end

  defp document_response?(_params, _lid, _fid), do: false

  # The document a navigation wait is pinned to. `loader`/`frame` are the Page.navigate
  # result's (nil when absent — see own_loader?/3): the response capture correlates on
  # `loader` for the whole wait. `wait_loader` is the loader whose milestone ends the
  # wait; it starts as `loader` and track_lifecycle/2 re-pins it to a successor document.
  # `committed` records that our own document has emitted a lifecycle event.
  defp navigation(lid, fid), do: %{loader: lid, frame: fid, wait_loader: lid, committed: false}

  # Classify a lifecycle event against the pinned navigation. Chrome emits `init` for
  # every new document on a frame, and a document can only be replaced after it has
  # committed, so an `init` on our frame with another loaderId AFTER our own document's
  # first lifecycle event is a successor — a meta refresh, a JS location change, a
  # waiting-room bounce. Its milestone must end the wait: the original document is gone
  # and never reaches network-quiet, so without the re-pin the wait would only end at
  # the deadline. Before our document commits, the same shape is a predecessor (see
  # own_loader?/3) and stays stale. Puppeteer's LifecycleWatcher gets the same result
  # by accepting any loader other than the pre-navigation one; we don't track the
  # frame's loader before navigating, so we pin to the navigate result and re-pin.
  defp track_lifecycle(params, nav) do
    cond do
      own_loader?(params, nav.wait_loader, nav.frame) ->
        {:ours, %{nav | committed: true}}

      nav.committed and params["name"] == "init" and correlates?(params["frameId"], nav.frame) ->
        {:successor, %{nav | wait_loader: params["loaderId"]}}

      true ->
        {:stale, nav}
    end
  end

  # Does this lifecycle event belong to the document we are waiting on? A fresh page's
  # about:blank document emits networkAlmostIdle ~500ms after the target is created (its
  # network-quiet timer, counted from target creation), and Chrome *replays* lifecycle
  # events for the current document whenever Page.setLifecycleEventsEnabled(true) is
  # called — both carry the PREVIOUS loaderId and can land mid-navigation, closing the
  # wait on a document that is not the one being navigated to.
  #
  # Correlation only *rejects* when both sides carry the id and they differ: `loaderId`
  # is optional on the Page.navigate result (and, in principle, on the event), and
  # treating an absent id as a mismatch would make the milestone unmatchable — turning a
  # prompt return into a full-timeout hang. Same rule for frameId, which also guards
  # against a sub-frame's milestone.
  defp own_loader?(params, lid, fid),
    do: correlates?(params["loaderId"], lid) and correlates?(params["frameId"], fid)

  defp correlates?(nil, _expected), do: true
  defp correlates?(_actual, nil), do: true
  defp correlates?(actual, expected), do: actual == expected

  defp response_summary(%{"response" => response} = params) do
    headers = response["headers"]

    %{
      status: response["status"],
      url: response["url"],
      headers: if(is_map(headers), do: headers, else: %{}),
      request_id: params["requestId"]
    }
  end

  # Generic mailbox drain for one cdp method.
  defp drain_events(conn, method) do
    receive do
      {:cdp_event, ^conn, ^method, _params, _sid} -> drain_events(conn, method)
    after
      0 -> :ok
    end
  end

  # Subscribe to lifecycle events, run `trigger` (issue the navigation, or a no-op),
  # then await the `name` milestone — always unsubscribing + draining on the way out.
  # Subscribing BEFORE `trigger` closes the race where a fast event (e.g. `load` on
  # a cached page) fires before the listener is in place. Returns await_lifecycle/5's
  # outcome (`:reached` | `{:down, reason}` | `:timeout`), or `{:error, reason}` when
  # subscription fails or `trigger` returns one.
  #
  # `trigger` returns `{:ok, loader_id, frame_id}` to pin the wait to that navigation's
  # document (navigate/3) or a bare `:ok` when there is nothing to pin it to
  # (wait_for_navigation/2, where the caller — a click, say — triggered the navigation
  # out of band and no loaderId is available; it keeps the pre-existing name-only match).
  defp subscribe_then_await(page, name, deadline, trigger) do
    case subscribe_each(page.conn, [@lifecycle_method], remaining(deadline), page.session_id) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        drain_events(page.conn, @lifecycle_method)
        ref = Process.monitor(page.conn)
        watch = watch_detach(page, deadline)
        await = &await_lifecycle(page, name, {ref, watch_tag(watch)}, deadline, &1)

        try do
          case trigger.() do
            :ok -> await.(navigation(nil, nil))
            {:ok, lid, fid} -> await.(navigation(lid, fid))
            {:error, _} = error -> error
          end
        after
          stop_watch(watch)
          Process.demonitor(ref, [:flush])
          :ok = unsubscribe_each(page.conn, [@lifecycle_method], page.session_id)
          drain_events(page.conn, @lifecycle_method)
        end
    end
  end

  # With nothing to send, a wait on a session that detached before the watcher
  # subscribed would only time out: one round trip after subscribing surfaces Chrome's
  # "session not found" as {:session_closed, sid}. Any other answer, or none within
  # @probe_timeout (an endpoint that drops the call), means carry on.
  defp probe_session(%__MODULE__{session_id: nil}, _deadline), do: :ok

  defp probe_session(page, deadline) do
    timeout = min(remaining(deadline), @probe_timeout)

    case do_call(page, "Target.getTargetInfo", %{}, timeout) do
      {:error, {:session_closed, _sid}} = error -> error
      _answered -> :ok
    end
  end

  # A `:session` page's connection is the shared browser socket, which outlives the
  # page, so a wait that ends on the connection's :DOWN also watches for the
  # session's detach — the session-transport equivalent (#121). The helper-run waits
  # subscribe to it on their own pid.
  defp watched(%__MODULE__{session_id: nil}, methods), do: methods
  defp watched(_page, methods), do: [@target_detached | methods]

  # The caller-run wait can't subscribe to the detach itself: unsubscribing would drop
  # a subscription the caller holds on that browser-wide method, and the drain would
  # eat its queued events. A monitored watcher subscribes instead and sends
  # `{tag, {:session_closed, sid}}`; Connection prunes its subscription when it exits.
  # Returns `{pid, monitor, tag}`, or nil for a dedicated page or a failed subscribe:
  # it is bounded by the wait's own deadline, so a failure means either that deadline
  # is spent or the connection is dead, which the wait reports by itself.
  defp watch_detach(%__MODULE__{session_id: nil}, _deadline), do: nil

  defp watch_detach(%__MODULE__{conn: conn, session_id: sid} = page, deadline) do
    parent = self()
    tag = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        ProcessLabel.set({:cdp_page_helper, :detach_watch, page.target_id})
        parent_mon = Process.monitor(parent)

        case subscribe_each(conn, [@target_detached], remaining(deadline), sid) do
          :ok -> report_detach(conn, sid, {parent, parent_mon}, tag)
          {:error, _reason} -> :ok
        end
      end)

    receive do
      {^tag, :watching} -> {pid, mon, tag}
      {:DOWN, ^mon, :process, ^pid, _reason} -> nil
    end
  end

  defp report_detach(conn, sid, {parent, parent_mon}, tag) do
    send(parent, {tag, :watching})

    receive do
      {:cdp_event, ^conn, @target_detached, %{"sessionId" => ^sid}, _parent} ->
        send(parent, {tag, {:session_closed, sid}})

      {:DOWN, ^parent_mon, :process, ^parent, _reason} ->
        :ok
    end
  end

  # A process's messages arrive before its :DOWN, so once the :DOWN is in, a late
  # `{tag, _}` can be flushed for good.
  defp stop_watch(nil), do: :ok

  defp stop_watch({pid, mon, tag}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^tag, _} -> :ok
    after
      0 -> :ok
    end
  end

  # A tag no message carries, so a dedicated page's wait never matches the clause.
  defp watch_tag(nil), do: make_ref()
  defp watch_tag({_pid, _mon, tag}), do: tag

  # Wait for the named lifecycle event — scoped to this page's session (the
  # subscription filters on it; `^sid` keeps the match honest) and the
  # `Page.lifecycleEvent` method (the subscription is method-keyed, so other
  # methods never arrive here) — the connection dying, the session's detach, or the
  # deadline. The milestone
  # is pinned to the navigated document per track_lifecycle/2 (a stale about:blank
  # milestone can't end the wait early; a successor document's can); with no loaderId
  # in `nav` it matches on name alone. Returns `:reached` | `{:down, reason}` |
  # `:timeout`; callers map it to their own contract.
  defp await_lifecycle(%__MODULE__{conn: conn, session_id: sid} = page, name, mons, deadline, nav) do
    {ref, tag} = mons
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:cdp_event, ^conn, @lifecycle_method, %{"name" => event} = params, ^sid} ->
        case track_lifecycle(params, nav) do
          {:ours, _nav} when event == name -> :reached
          {_, nav} -> await_lifecycle(page, name, mons, deadline, nav)
        end

      {^tag, {:session_closed, _sid} = reason} ->
        {:down, reason}

      {:cdp_event, ^conn, @lifecycle_method, _params, _session_id} ->
        await_lifecycle(page, name, mons, deadline, nav)

      {:DOWN, ^ref, :process, ^conn, reason} ->
        {:down, reason}
    after
      remaining ->
        # Exact deadline-vs-DOWN tie: a {:DOWN} (or the detach) may have just landed
        # but lost the race to `after`. Prefer it over a misleading timeout.
        receive do
          {:DOWN, ^ref, :process, ^conn, reason} -> {:down, reason}
          {^tag, {:session_closed, _sid} = reason} -> {:down, reason}
        after
          0 -> :timeout
        end
    end
  end

  defp down_reason({:session_closed, _sid} = reason), do: reason
  defp down_reason({:shutdown, {:ws_closed, reason}}), do: {:ws_closed, reason}
  defp down_reason(_), do: :noproc

  defp lifecycle_name(:load), do: "load"
  defp lifecycle_name(:network_almost_idle), do: "networkAlmostIdle"

  # Both navigate/3 and wait_for_navigation/2 route through here. Fail fast on an
  # unknown value rather than silently waiting for the wrong milestone (`:none` is
  # handled by the callers before this point).
  defp lifecycle_name(other) do
    raise ArgumentError,
          "invalid :wait_until #{inspect(other)} (expected :network_almost_idle, :load, or :none)"
  end

  @doc """
  Waits for a navigation lifecycle milestone, without issuing a navigation.

  Useful after a `click/3` (or other in-page action) that triggers navigation.

  Options:
    * `:wait_until` — `:network_almost_idle` (default), `:load`, or `:none`
    * `:timeout` — ms (default 30_000)

  Returns `:ok`, `{:error, :timeout}`, or `{:error, reason}` if the connection
  drops while waiting. On a `:session` page it also returns
  `{:error, {:session_closed, session_id}}` when the session detaches, and makes one
  `Target.getTargetInfo` call before waiting so that a session already gone fails
  at once rather than at `:timeout`.
  """
  @spec wait_for_navigation(t(), keyword()) :: :ok | {:error, term()}
  def wait_for_navigation(%__MODULE__{frame: nil} = page, opts \\ []) do
    case Keyword.get(opts, :wait_until, :network_almost_idle) do
      :none -> :ok
      wait_until -> await_navigation(page, wait_until, opts)
    end
  end

  # Same machinery as navigate/3 (subscribe-before-wait, scoped to this session +
  # the Page.lifecycleEvent method) but without issuing a navigation — the caller
  # already triggered one (e.g. a click). Unlike the previous await_event matcher,
  # this can't be tripped by params from another event method carrying a "name".
  defp await_navigation(page, wait_until, opts) do
    name = lifecycle_name(wait_until)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @navigate_timeout)

    case subscribe_then_await(page, name, deadline, fn -> probe_session(page, deadline) end) do
      :reached -> :ok
      :timeout -> {:error, :timeout}
      {:down, reason} -> {:error, down_reason(reason)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Arms HTTP/proxy authentication on this page with `username`/`password`.

  Headless Chrome launched with `--proxy-server=host:port` can't send proxy
  credentials, so an authenticated proxy rejects the connection
  (`net::ERR_INVALID_AUTH_CREDENTIALS`). Call this after `new_page/2` and
  **before** `navigate/3`: it answers the proxy (or HTTP Basic) auth challenge with
  the given credentials. It also covers Basic-auth-gated origins.

  This enables the CDP `Fetch` domain for the page, which pauses (and
  auto-continues) **every** request — measurable overhead on heavy pages. It
  combines with `enable_request_interception/2` on the same page, in either order.

  Works on `:dedicated` and `:session` pages. A `:session` page's handler shares the
  browser connection and stops when the page's session ends: on `close_page/2`, a tab
  closed from outside, or a crash. Chrome caches the credentials it was given for
  the page's browser context, so other pages in that context may reuse them. A page that isn't one
  of this browser's open pages returns `{:error, :unknown_page}`, a page that is
  already authenticated returns `{:error, :already_authenticated}`. A browser
  that is gone returns `{:error, :noproc}`, and one that can't arm the handler within
  15s returns `{:error, {:timeout, :authenticate}}`.

  If an earlier `authenticate/4` on this page was abandoned while still arming (e.g. its
  call timed out under heavy load), its auth is dropped automatically and the page
  becomes re-authenticatable — a retry succeeds once that completes (it may briefly
  still see `{:error, :already_authenticated}` in the meantime).
  A timeout can also race the handler finishing arming, leaving the page authenticated
  after all: a retry then returns `{:error, :already_authenticated}` for good, which
  means the page is armed.

  The bad-credentials loop guard keys on the request id, so a single request that
  must answer **both** a proxy and an origin challenge isn't supported — the second
  challenge is cancelled (Puppeteer-parity).

  Options:
    * `:source` — which challenges to answer: `:any` (default), `:proxy`, `:server`.
      An unknown value returns `{:error, {:invalid_source, value}}`.
  """
  @spec authenticate(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def authenticate(%__MODULE__{frame: nil} = page, username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    case validate_source(Keyword.get(opts, :source, :any)) do
      :ok ->
        # As a closure, so no crash report or process status prints the credentials.
        credentials = fn -> {username, password} end
        Browser.authenticate(page.browser, page, [credentials: credentials] ++ opts)

      {:error, _} = error ->
        error
    end
  end

  defp validate_source(source) when source in [:any, :proxy, :server], do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  @doc """
  Evaluates a JavaScript expression and returns its value (`returnByValue`).

  A thrown JS exception is `{:error, {:evaluate_exception, details}}`.

  The value must be JSON-serializable. Under `returnByValue`, three results are
  worth knowing (return a serializable projection like `el.outerHTML` / `el.id`
  to avoid them):

    * a DOM node or function serializes **lossily** to `{:ok, %{}}` — an empty
      map, not the object and not an error;
    * an unserializable number Chrome reports only as an `unserializableValue`
      (`NaN`, `Infinity`, `-0`, a `BigInt`) has no by-value value and surfaces as
      `{:error, {:unserializable_value, uv}}` (the raw string, e.g. `"NaN"`);
    * a value Chrome can't serialize at all — a self-referential object like
      `window`, a circular structure, or a `Symbol` — fails the call as
      `{:error, {:cdp_error, "Runtime.evaluate", _}}`.

  Options: `:timeout` (default 15_000), `:await_promise` (default `false`).
  """
  @spec evaluate(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(%__MODULE__{} = page, js, opts \\ []) when is_binary(js) do
    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    params = %{
      "expression" => js,
      "returnByValue" => true,
      "awaitPromise" => Keyword.get(opts, :await_promise, false)
    }

    with {:ok, route, context_id} <- route(page, timeout),
         params = put_context(params, "contextId", context_id),
         {:ok, result} <- do_call(route, "Runtime.evaluate", params, timeout) do
      Protocol.evaluate_result(result)
    end
  end

  @doc "Returns the page's full serialized HTML (`document.documentElement.outerHTML`)."
  @spec html(t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def html(%__MODULE__{} = page, opts \\ []) do
    evaluate(page, "document.documentElement.outerHTML", opts)
  end

  @doc """
  Calls a JavaScript function with `args` and returns its value.

  `function_declaration` is a JS function expression (e.g. `"(a, b) => a + b"`).
  `args` are JSON-encoded (not string-interpolated) before being applied, so
  passing data values through them is safe. A thrown exception is
  `{:error, {:evaluate_exception, details}}`; non-serializable `args` return
  `{:error, {:invalid_args, reason}}`.

  > #### Trusted input {: .warning}
  >
  > `function_declaration` is interpolated into the page script **verbatim** —
  > treat it as trusted code and never build it from untrusted input.

  Options: `:timeout` (default 15_000), `:await_promise` (default `false`).
  """
  @spec call_function(t(), String.t(), [term()], keyword()) :: {:ok, term()} | {:error, term()}
  def call_function(%__MODULE__{} = page, function_declaration, args \\ [], opts \\ [])
      when is_binary(function_declaration) and is_list(args) do
    case Jason.encode(args) do
      {:ok, json} ->
        evaluate(page, "(#{function_declaration}).apply(undefined, #{json})", opts)

      {:error, reason} ->
        {:error, {:invalid_args, reason}}
    end
  end

  @doc """
  Waits until `css` matches an element, or `timeout` elapses.

  The check runs inside the page on every DOM mutation, so a matching element is
  seen as soon as it is inserted (see `wait_for_function/3`).

  The selector is `Jason.encode!`-ed into the injected `document.querySelector(...)`
  call, so quote characters in attribute selectors (`[id^='ticket-card-']`,
  `[data-x="foo"]`) reach the page intact — no naive string concatenation.

  Returns `:ok`, `{:error, :timeout}`, or `{:error, reason}` if a non-transient
  evaluate error occurs — including `{:error, {:evaluate_exception, _}}` when
  `querySelector` itself throws (e.g. a syntactically invalid CSS selector). A
  transient CDP error (e.g. the execution context is rebuilding mid-navigation)
  keeps polling; a thrown JS exception is fatal so a bad selector doesn't hide as
  a perpetual no-match, and so is a closed page (`:noproc`, or
  `{:session_closed, _}` on a `:session` page). Options: `:timeout` (default
  5_000), `:interval` (poll interval ms, default 100).
  """
  @spec wait_for_selector(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_selector(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    wait_for_function(page, "document.querySelector(#{Jason.encode!(css)}) !== null", opts)
  end

  @doc """
  Waits until a JavaScript expression is truthy, or `timeout` elapses.

  The wait runs inside the page as one `Runtime.evaluate` that awaits a promise:
  the expression is checked at once, then again on every DOM mutation (a
  `MutationObserver` on the whole document) and every `:interval` ms, so a DOM
  change is seen as soon as it happens rather than at the next poll, with no CDP
  round trip per check. The `:interval` timer covers state the DOM doesn't
  reflect (a JS variable, a timer). A navigation that replaces the document
  rejects the in-flight wait with a CDP error, and the wait is re-armed in the
  new document for the time left. Keep the expression cheap: on a page that
  mutates constantly it runs once per batch of mutations.

  The expression is coerced with `!!(...)`, so JS truthiness applies. Returns
  `:ok`, `{:error, :timeout}`, or `{:error, reason}` if a non-transient evaluate
  error occurs. A transient CDP error (e.g. the execution context is rebuilding
  mid-navigation) keeps polling; a non-transient one is fatal — including
  `{:error, {:evaluate_exception, _}}` when the expression itself throws, a
  dropped connection, and a closed page (`:noproc`, or `{:session_closed, _}` on a
  `:session` page, whose detach Chrome reports as "session not found"). This is
  the shared error taxonomy behind `wait_for_selector/3`.
  Options: `:timeout` (default 5_000), `:interval` (ms between timer-driven
  checks, default 100). Both must be at most 2_147_483_647 ms (about 24.8 days),
  the longest delay a browser timer holds; a larger value raises `ArgumentError`.
  """
  @spec wait_for_function(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_function(%__MODULE__{} = page, js, opts \\ []) when is_binary(js) do
    timeout = wait_opt!(opts, :timeout, @selector_timeout, 0)
    interval = wait_opt!(opts, :interval, 100, 1)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_truthy(page, js, interval, deadline)
  end

  # Both values are interpolated into the in-page script, so anything but an
  # integer in range is refused here rather than surfacing as a JS error.
  defp wait_opt!(opts, key, default, min) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= min and value <= @max_timer_ms ->
        value

      other ->
        raise ArgumentError,
              "invalid #{inspect(key)} #{inspect(other)} (expected an integer in #{min}..#{@max_timer_ms})"
    end
  end

  # One in-page wait per document: it settles true as soon as the expression is
  # truthy, or false when the time left runs out. A CDP error means the document
  # went away under it (the execution context was destroyed or isn't ready yet
  # mid-navigation), so re-arm after `interval` for whatever time is left.
  defp await_truthy(page, js, interval, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    script = in_page_wait(js, interval, remaining)

    case evaluate(page, script, await_promise: true, timeout: remaining + @wait_grace) do
      {:ok, true} ->
        :ok

      # The in-page timer ran out, or (throttled timers in a background page) our
      # own guard did first.
      {:ok, _not_true} ->
        {:error, :timeout}

      {:error, {:timeout, "Runtime.evaluate"}} ->
        {:error, :timeout}

      {:error, {:cdp_error, _method, _info}} ->
        rearm_after_cdp_error(page, js, interval, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rearm_after_cdp_error(page, js, interval, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:error, :timeout}

      left ->
        Process.sleep(min(interval, left))
        await_truthy(page, js, interval, deadline)
    end
  end

  # The promise the page awaits. It checks the expression now, on every DOM
  # mutation and every `interval` ms, and settles once: true on a truthy check,
  # false after `timeout` ms, or rejected with whatever the expression throws (so
  # a bad selector is an `:evaluate_exception`, not a silent no-match). Every exit
  # disconnects the observer and clears both timers, so nothing outlives the wait.
  defp in_page_wait(js, interval, timeout) do
    """
    new Promise((resolve, reject) => {
      let settled = false, observer = null, poll = null, timer = null;
      const settle = (fn, value) => {
        if (settled) return;
        settled = true;
        if (observer) observer.disconnect();
        clearInterval(poll);
        clearTimeout(timer);
        fn(value);
      };
      const check = () => {
        let ok;
        try { ok = !!(#{js}); } catch (e) { settle(reject, e); return; }
        if (ok) settle(resolve, true);
      };
      check();
      if (settled) return;
      observer = new MutationObserver(check);
      observer.observe(document, {childList: true, subtree: true, attributes: true, characterData: true});
      poll = setInterval(check, #{interval});
      timer = setTimeout(() => settle(resolve, false), #{timeout});
    })
    """
  end

  @doc """
  Returns the `textContent` of the first element matching `css`, or `nil` when
  no element matches.
  """
  @spec text(t(), String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def text(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    sel = Jason.encode!(css)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      return el ? el.textContent : null;
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Returns attribute `name` of the first element matching `css`, or `nil` when the
  element or attribute is absent.
  """
  @spec attribute(t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def attribute(%__MODULE__{} = page, css, name, opts \\ [])
      when is_binary(css) and is_binary(name) do
    sel = Jason.encode!(css)
    attr = Jason.encode!(name)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      return el ? el.getAttribute(#{attr}) : null;
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Returns `{:ok, true}` when the first element matching `css` is rendered and
  visible (has layout boxes, not `display: none` / `visibility: hidden`),
  `{:ok, false}` otherwise — including when no element matches.
  """
  @spec visible?(t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def visible?(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    sel = Jason.encode!(css)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      if (!el) return false;
      const s = window.getComputedStyle(el);
      return el.getClientRects().length > 0 && s.visibility !== "hidden" && s.display !== "none";
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Clicks the first element matching `css` with a real, trusted mouse event.

  Scrolls the element into view, then dispatches `Input.dispatchMouseEvent`
  `mousePressed`/`mouseReleased` at a point on it, so `event.isTrusted` is `true`.

  The point is the centre of the in-view part of the element's first client rect
  (one per line box, so a link that wraps onto a second line is clicked on its
  text, not in the gap between its lines), checked with `elementFromPoint`: the
  element there must be the target or one of its descendants. When it is
  something else (a cookie banner, a modal backdrop, a sibling positioned on top,
  or the page behind a `pointer-events: none` target) the next rect is tried, and
  with none left the call returns `{:error, {:obscured, css}}` without clicking.
  Both errors reflect the layout at call time; on pages that render or animate
  content in late (an SPA that hydrates after load, an overlay that fades out),
  pass `:wait` so the click retries until the element is there and on top.

  Options:
    * `:wait` — total milliseconds to keep retrying while the element is missing
      (`:selector_not_found`), has no box yet (`:not_clickable`), is covered
      (`:obscured`), or the lookup
      finds no execution context (a `{:cdp_error, _, _}` while the page is
      mid-navigation), waiting #{@click_poll_interval}ms between attempts; the last
      of those errors is returned once the budget is spent. Any other CDP error
      returns immediately, as does one from the mouse dispatch (the press may
      already have landed), an evaluate exception, a timeout, a dropped
      connection, or a closed page (`:noproc`, or `{:session_closed, _}` on a
      `:session` page). Each attempt locates and clicks in one step, so there is
      no gap between "found" and "clicked".
      The budget bounds the retrying, not an attempt already in flight, so the
      worst case is about `wait` plus one attempt's CDP calls (each bounded by
      `:timeout`). Default `0` (a single attempt); anything but a non-negative
      integer raises `ArgumentError`.
    * `:trusted` — `false` falls back to a synthetic JS `.click()` (no
      hit-testing, `event.isTrusted == false`); the escape hatch for elements not
      at a clickable point. It clicks the element whatever its box and whatever
      covers it, so it never returns `:not_clickable` or `:obscured`, and `:wait`
      only waits for the element to exist.
      The lookup and the click are one script there, so `:wait` retries a CDP
      error only when the context was never found; one torn down mid-call may be
      the click's own navigation, and a retry would click twice. Default `true`.
    * `:timeout` — per-CDP-call timeout, default #{@evaluate_timeout}.

  Returns `:ok`, `{:error, {:selector_not_found, css}}` when nothing matches,
  `{:error, {:not_clickable, css}}` when the element has no usable box (zero-size
  or not in the viewport even after scroll), or `{:error, {:obscured, css}}` when
  another element is on top of every part of it in view (trusted clicks only).
  """
  @spec click(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def click(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    locator = "document.querySelector(#{Jason.encode!(css)})"
    click_with_wait(page, locator, {:selector_not_found, css}, css, opts)
  end

  @doc """
  Clicks the element whose text content is `text` — a button or link by its label.

  Text is compared after collapsing internal whitespace and trimming both sides
  (XPath `normalize-space()` semantics), against each candidate's `textContent`;
  the match is exact after that normalization. Being `textContent`, it includes the
  text of hidden descendants, and as in XPath only space, tab, CR and LF count as
  whitespace (`&nbsp;` does not). A wrapping container's text equals
  its only child's, so when matches nest the **innermost** one is clicked: in
  `<div><button>Load more</button></div>` that is the button, not the div.

  Each innermost match is first resolved to its click target: itself if it has a box,
  otherwise (unless it is `display: none`) its nearest matching HTML ancestor that
  has one. The first target in document order **that is visible** (a non-zero box,
  not `visibility: hidden` or `opacity: 0`) wins, so a hidden copy of the label
  earlier in the page (a collapsed mobile menu, say) doesn't shadow the visible one;
  a copy moved off-canvas with a transform is not detected. Failing that, the first
  target with a box wins. The climb is what makes an SVG `<title>` in an icon button,
  or a `display: contents` span in a link, click the button or the link (not the
  `<svg>`, which has a box and the same text but isn't an HTML element). When nothing
  has a box the first innermost match is chosen, and a trusted click reports
  `:not_clickable`.

  Candidates are the elements under `document.body`, never inside `<script>`,
  `<style>`, `<template>` or `<noscript>`; text in such a child still counts toward its
  parent's `textContent`, so a button with an inline `<svg><style>` doesn't match its
  label (use `click/3` with a selector there). `:selector` narrows candidates to
  those matching a CSS selector (e.g. `selector: "button, a"`), which also stops a
  label from matching unrelated text elsewhere on the page. The search doesn't enter
  shadow roots or iframes, and its cost grows with the page's text (it re-runs on every
  `:wait` attempt).

  Clicks the same way as `click/3` — trusted by default, synthetic with
  `trusted: false`, with the same hit test. A synthetic click picks the same
  element but clicks it whatever its box and whatever covers it, so it never
  reports `:not_clickable` or `:obscured`. The choice among matches looks at
  visibility, not at what covers them: a visible match under an overlay is still
  chosen, and the trusted click reports `:obscured`.

  Options:
    * `:selector` — CSS selector (a string) the candidates must match; any other
      value raises `ArgumentError`. Default: any element.
    * `:wait` — as in `click/3`, retrying while nothing matches, the match has no
      box yet or is covered (trusted clicks only), or the lookup finds no
      execution context.
      Default `0`; an invalid value raises `ArgumentError`.
    * `:trusted` — as in `click/3`. Default `true`.
    * `:timeout` — per-CDP-call timeout, default #{@evaluate_timeout}.

  An empty or whitespace-only `text` raises `ArgumentError`: after normalization it
  would match any element with no text.

  Returns `:ok`, `{:error, {:text_not_found, text}}` when no candidate matches,
  `{:error, {:not_clickable, text}}` when the match has no usable box,
  `{:error, {:obscured, text}}` when another element covers it, or
  `{:error, {:evaluate_exception, _}}` for an invalid `:selector`.
  """
  @spec click_text(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def click_text(%__MODULE__{} = page, text, opts \\ []) when is_binary(text) do
    if blank_text?(text) do
      raise ArgumentError,
            "invalid click_text/3 text #{inspect(text)} (expected a non-whitespace label)"
    end

    selector = text_selector!(Keyword.get(opts, :selector))
    locator = text_locator(text, selector)
    click_with_wait(page, locator, {:text_not_found, text}, text, opts)
  end

  @doc """
  Moves the mouse over the first element matching `css` with a real
  `Input.dispatchMouseEvent` `mouseMoved`, so the page sees `mouseover`,
  `mouseenter` and `mousemove` with `event.isTrusted == true` and CSS `:hover`
  applies: the way to open a menu that shows on hover.

  The element is located, scrolled into view and hit-tested exactly as in
  `click/3`, so the errors are the same: `{:error, {:selector_not_found, css}}`,
  `{:error, {:not_clickable, css}}` when it has no box in the viewport, and
  `{:error, {:obscured, css}}` when another element is on top of it. The pointer
  stays there until the next mouse event, so a later `click/3` elsewhere moves it
  away (and fires `mouseleave`).

  Options:
    * `:wait` — as in `click/3`: milliseconds to keep retrying while the element is
      missing, has no box or is covered. Default `0`.
    * `:timeout` — per-CDP-call timeout, default #{@evaluate_timeout}.
  """
  @spec hover(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def hover(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    locator = "document.querySelector(#{Jason.encode!(css)})"
    not_found = {:selector_not_found, css}
    with_wait(opts, fn -> trusted_mouse(page, locator, not_found, css, :hover, opts) end)
  end

  @doc """
  Scrolls the window to `target`: `:top` or `:bottom` of the document (keeping the
  horizontal position), or `{x, y}` document coordinates.

  The scroll is instant even on a page that sets `scroll-behavior: smooth`, so
  `window.scrollY` reflects it as soon as this returns. Content a page loads in
  response (infinite scroll) arrives later — follow up with `wait_for_selector/3`,
  `wait_for_function/3`, or `wait_for_network_idle/2`.

  This scrolls the window only. An app whose scroll container is an inner element
  (`body { overflow: hidden }` around a scrolling `<main>`) needs `evaluate/3` on that
  element, e.g. `el.scrollTop = el.scrollHeight`.

  Returns `:ok` or `{:error, reason}`; any other `target` raises `FunctionClauseError`.
  Option: `:timeout` (default #{@evaluate_timeout}).
  """
  @spec scroll(t(), :top | :bottom | {number(), number()}, keyword()) :: :ok | {:error, term()}
  def scroll(page, target, opts \\ [])

  def scroll(%__MODULE__{} = page, :top, opts), do: scroll_to(page, "window.scrollX", "0", opts)

  def scroll(%__MODULE__{} = page, :bottom, opts) do
    height =
      "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"

    scroll_to(page, "window.scrollX", height, opts)
  end

  def scroll(%__MODULE__{} = page, {x, y}, opts) when is_number(x) and is_number(y),
    do: scroll_to(page, Jason.encode!(x), Jason.encode!(y), opts)

  defp scroll_to(page, left, top, opts) do
    js = """
    (function () {
      window.scrollTo({left: #{left}, top: #{top}, behavior: "instant"});
      return true;
    })()
    """

    case evaluate(page, js, opts) do
      {:ok, true} -> :ok
      {:ok, other} -> {:error, {:unexpected_evaluate, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Types `text` into the first element matching `css`.

  Focuses the element, then sends the text via `Input.insertText` (fires `input`
  and `change`; does not emit per-character `keydown`/`keyup`).

  Returns `:ok` or `{:error, {:selector_not_found, css}}`. Option: `:timeout`
  (default #{@evaluate_timeout}).
  """
  @spec type(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def type(%__MODULE__{} = page, css, text, opts \\ []) when is_binary(css) and is_binary(text) do
    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    case focus(page, css, opts) do
      :ok ->
        case do_call(top(page), "Input.insertText", %{"text" => text}, timeout) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sets the files of the first `<input type="file">` matching `css`
  (`DOM.setFileInputFiles`), as if the user picked them: the input's `files` change
  and it fires `input` and `change`. An empty list clears the selection
  (`DOM.setFileInputFiles` can't) by setting the input's `value` to `""` and
  dispatching `input` and `change` from script, so those two are not trusted.

  `paths` is a path or a list of paths, expanded with `Path.expand/1`. Chrome reads
  the files itself, from its own filesystem, and takes a missing one without
  complaint: the page sees a 0-byte file that fails when read. So each path is
  first checked to be a regular file here. For a browser attached with
  `CDPEx.connect/2` that runs on another host or in a container, the paths are on
  its filesystem, not the caller's: pass `check: false`.

  More than one path for an input without the `multiple` attribute is refused
  (Chrome would keep one and fire no event).

  Returns `:ok`, `{:error, {:file_not_found, path}}` (the expanded path),
  `{:error, {:selector_not_found, css}}`, `{:error, {:not_file_input, css}}` when
  the element is not an `<input type="file">`,
  `{:error, {:invalid_args, {:multiple_files, css}}}`,
  `{:error, {:evaluate_exception, _}}` for an invalid selector, or a CDP error.
  A `paths` that is not a string or a list of strings raises `ArgumentError`.

  Options:
    * `:check` — `false` skips the local file check. Default `true`.
    * `:timeout` — per-CDP-call timeout, default #{@evaluate_timeout}.
  """
  @spec set_input_files(t(), String.t(), Path.t() | [Path.t()], keyword()) ::
          :ok | {:error, term()}
  def set_input_files(%__MODULE__{} = page, css, paths, opts \\ []) when is_binary(css) do
    files = paths |> input_paths!() |> Enum.map(&Path.expand/1)

    case Keyword.get(opts, :check, true) && Enum.find(files, &(not File.regular?(&1))) do
      missing when is_binary(missing) -> {:error, {:file_not_found, missing}}
      _ -> do_set_input_files(page, css, files, Keyword.get(opts, :timeout, @evaluate_timeout))
    end
  end

  defp do_set_input_files(page, css, files, timeout) do
    js = """
    (function () {
      var el = document.querySelector(#{Jason.encode!(css)});
      if (!el) { return "not_found"; }
      if (!(el instanceof HTMLInputElement) || el.type !== "file") { return "not_file_input"; }
      if (#{length(files)} > 1 && !el.multiple) { return "not_multiple"; }
      if (#{length(files)} === 0) {
        el.value = "";
        el.dispatchEvent(new Event("input", {bubbles: true, composed: true}));
        el.dispatchEvent(new Event("change", {bubbles: true}));
        return "cleared";
      }
      return el;
    })()
    """

    with {:ok, route, context_id} <- route(page, timeout) do
      params =
        put_context(
          %{"expression" => js, "objectGroup" => @files_object_group},
          "contextId",
          context_id
        )

      route
      |> do_call("Runtime.evaluate", params, timeout)
      |> files_result(route, css, files, timeout)
    end
  end

  defp files_result(result, route, css, files, timeout) do
    case result do
      {:ok, %{"result" => %{"objectId" => object_id}} = result}
      when not is_map_key(result, "exceptionDetails") ->
        set_files(route, object_id, files, timeout)

      {:ok, %{"result" => %{"value" => "cleared"}}} ->
        :ok

      {:ok, %{"result" => %{"value" => "not_found"}}} ->
        {:error, {:selector_not_found, css}}

      {:ok, %{"result" => %{"value" => "not_file_input"}}} ->
        {:error, {:not_file_input, css}}

      {:ok, %{"result" => %{"value" => "not_multiple"}}} ->
        {:error, {:invalid_args, {:multiple_files, css}}}

      {:ok, %{"exceptionDetails" => details}} ->
        {:error, {:evaluate_exception, details}}

      {:ok, other} ->
        {:error, {:unexpected_evaluate, other}}

      {:error, _} = error ->
        error
    end
  end

  defp set_files(page, object_id, files, timeout) do
    result =
      do_call(page, "DOM.setFileInputFiles", %{"files" => files, "objectId" => object_id}, timeout)

    _ =
      do_call(page, "Runtime.releaseObjectGroup", %{"objectGroup" => @files_object_group}, timeout)

    case result do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp input_paths!(paths) do
    if (is_binary(paths) or is_list(paths)) and Enum.all?(List.wrap(paths), &is_binary/1) do
      List.wrap(paths)
    else
      raise ArgumentError,
            "invalid set_input_files/4 paths #{inspect(paths)} (expected a path or a list of paths)"
    end
  end

  @doc """
  Returns a handle for the frame of the first `<iframe>` (or `<frame>`) matching
  `css`, for reading and acting inside it: the functions that work on an element or
  run script take the handle in place of the page and apply to the frame's
  document. Same-site and cross-site (out-of-process) frames alike; pass a frame
  handle as `page` to reach a frame nested in it.

  Inside a frame, `evaluate/3`, `call_function/4`, `html/2`, `text/3`,
  `attribute/4`, `wait_for_selector/3`, `wait_for_function/3`, `scroll/3`,
  `set_input_files/4` and the synthetic clicks run in the frame's main world, as on
  a page. `click/3`, `click_text/3` and `hover/3` dispatch trusted mouse events on
  the page, at the element's point shifted by each enclosing `<iframe>`: every
  `<iframe>` on the way is scrolled into view and must be what its parent has at
  that point, else `{:error, {:obscured, label}}`. `type/4` and `press/4` focus the
  element in the frame and send the keys to the page, which routes them there.
  The functions that act on the whole page (navigation and its waits, screenshots,
  PDF, cookies, network observation and interception, emulation, dialogs, login)
  take a page only: a frame handle raises `FunctionClauseError` there.

  The handle names the frame, not its document: where its script runs is looked up
  on every call, so it keeps working after the frame navigates, to another site
  (another process) included. While the new document has no context yet, and once
  the frame is removed, calls return `{:error, {:frame_unavailable, css}}`. Handles
  need no closing; a cross-site frame's session on the browser connection is reused
  for the same frame and ends with it or with the page.

  Returns `{:ok, frame}`, `{:error, {:selector_not_found, css}}`,
  `{:error, {:not_a_frame, css}}` when the element is no `<iframe>` or `<frame>`,
  `{:error, {:frame_unavailable, css}}` when the frame has no document to run
  script in yet (still loading), or a CDP error.

  Options:
    * `:wait` — milliseconds to keep retrying while the `<iframe>` is missing or its
      frame unavailable, #{@click_poll_interval}ms apart. Default `0`; anything but a
      non-negative integer raises `ArgumentError`.
    * `:timeout` — per-CDP-call timeout, default #{@evaluate_timeout}.
  """
  @spec frame(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def frame(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)
    attempt = fn -> find_frame(page, css, timeout) end

    case Keyword.get(opts, :wait, 0) do
      0 ->
        attempt.()

      wait when is_integer(wait) and wait > 0 ->
        retry_frame(attempt, System.monotonic_time(:millisecond) + wait)

      other ->
        raise ArgumentError, "invalid :wait #{inspect(other)} (expected a non-negative integer)"
    end
  end

  defp retry_frame(attempt, deadline) do
    case attempt.() do
      {:error, {tag, _}} = error when tag in [:selector_not_found, :frame_unavailable] ->
        if remaining(deadline) > 0 do
          Process.sleep(min(@click_poll_interval, remaining(deadline)))
          retry_frame(attempt, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  defp find_frame(page, css, timeout) do
    js = """
    (function () {
      var el = document.querySelector(#{Jason.encode!(css)});
      if (!el) { return "not_found"; }
      if (!(el instanceof HTMLIFrameElement || el instanceof HTMLFrameElement)) { return "not_frame"; }
      return el;
    })()
    """

    with {:ok, route, context_id} <- route(page, timeout) do
      group = "cdp_ex-frame-#{System.unique_integer([:positive])}"
      params = put_context(%{"expression" => js, "objectGroup" => group}, "contextId", context_id)

      result =
        route
        |> do_call("Runtime.evaluate", params, timeout)
        |> owner_result(page, route, css, timeout)

      _ = do_call(route, "Runtime.releaseObjectGroup", %{"objectGroup" => group}, timeout)
      result
    end
  end

  defp owner_result(result, page, route, css, timeout) do
    case result do
      {:ok, %{"result" => %{"objectId" => object_id}} = result}
      when not is_map_key(result, "exceptionDetails") ->
        describe_owner(page, route, object_id, css, timeout)

      {:ok, %{"result" => %{"value" => "not_found"}}} ->
        {:error, {:selector_not_found, css}}

      {:ok, %{"result" => %{"value" => "not_frame"}}} ->
        {:error, {:not_a_frame, css}}

      {:ok, %{"exceptionDetails" => details}} ->
        {:error, {:evaluate_exception, details}}

      {:ok, other} ->
        {:error, {:unexpected_evaluate, other}}

      {:error, _} = error ->
        error
    end
  end

  # The handle is checked once here, so a frame with no document yet is reported now;
  # each later call resolves its route again (see route/2).
  defp describe_owner(%__MODULE__{} = page, route, object_id, css, timeout) do
    case do_call(route, "DOM.describeNode", %{"objectId" => object_id}, timeout) do
      {:ok, %{"node" => %{"frameId" => frame_id, "backendNodeId" => owner} = node}} ->
        handle = %{page | frame: %{id: frame_id, label: css, parent: page, owner: owner}}
        loaded_frame(handle, node, timeout)

      {:ok, _no_frame} ->
        {:error, {:frame_unavailable, css}}

      {:error, _} = error ->
        error
    end
  end

  # An <iframe> shows the initial about:blank, in its parent's process, until its src
  # commits; a handle then would act on that empty document, so it waits for the real
  # one (srcdoc and about: sources excepted).
  defp loaded_frame(handle, node, timeout) do
    src = node |> Map.get("attributes", []) |> Enum.chunk_every(2) |> Enum.find_value(&src_attr/1)
    awaits_src? = is_binary(src) and not String.starts_with?(String.trim(src), "about:")

    case evaluate(handle, "location.href", timeout: timeout) do
      {:ok, "about:blank"} when awaits_src? -> {:error, {:frame_unavailable, handle.frame.label}}
      {:ok, _href} -> {:ok, handle}
      {:error, _} = error -> error
    end
  end

  defp src_attr(["src", value]), do: value
  defp src_attr(_attribute), do: nil

  @doc """
  Sets how the page's JavaScript dialogs are answered from now on: `alert`,
  `confirm`, `prompt` and `beforeunload`, its cross-site iframes' included.

  A dialog stops the page's JavaScript until it is answered, and with it any
  `evaluate/3` or trusted click waiting on that script, so the page's connection
  answers each one as it opens, before anything else sees it. The policies:

    * `:accept` (the default for every page) — OK: `confirm` returns `true`, `prompt`
      its default value (`""` when it has none).
    * `{:accept, text}` — as `:accept`, with `prompt` returning `text`.
    * `:dismiss` — Cancel: `confirm` returns `false`, `prompt` `null`.
    * `:manual` — no answer: the page stays paused until `handle_dialog/3`. To see
      the dialog, subscribe to `"Page.javascriptDialogOpening"` with
      `CDPEx.Connection.subscribe/4` (`page.conn`, `session_id: page.session_id`),
      and run whatever opens it in another process, since it won't return before
      the answer.

  `alert` has only OK, and `beforeunload` is accepted (the page is left) under
  every policy but `:manual`: staying would stall the navigation or close that
  raised it. Every dialog emits `[:cdp_ex, :dialog]` telemetry with its type,
  message and the action taken (see `CDPEx.Telemetry`).

  The default is set per page with `new_page/2`'s `:dialogs` option. Chrome
  answers natively, so `window.alert` and friends stay untouched for the page's
  own scripts.

  Returns `:ok` or `{:error, reason}` (`:noproc` once the page is gone). An invalid
  policy raises `ArgumentError`. Option: `:timeout` (default #{@evaluate_timeout}).
  """
  @spec set_dialogs(t(), Connection.dialog_policy(), keyword()) :: :ok | {:error, term()}
  def set_dialogs(%__MODULE__{frame: nil, conn: conn, session_id: session_id}, policy, opts \\ []) do
    Connection.set_dialogs(
      conn,
      session_id,
      policy,
      Keyword.get(opts, :timeout, @evaluate_timeout)
    )
  end

  @doc """
  Answers the dialog the page is showing (`Page.handleJavaScriptDialog`), for a page
  under `dialogs: :manual` (see `set_dialogs/3`): `:accept`, `:dismiss`, or
  `{:accept, text}` to answer a `prompt` with `text`. A plain `:accept` gives a
  prompt `""`, not its default value.

  Returns `:ok`, or `{:error, {:cdp_error, "Page.handleJavaScriptDialog", _}}` when
  no dialog is showing. Any other `answer` raises `ArgumentError`. Option:
  `:timeout` (default #{@evaluate_timeout}).
  """
  @spec handle_dialog(t(), :accept | :dismiss | {:accept, String.t()}, keyword()) ::
          :ok | {:error, term()}
  def handle_dialog(%__MODULE__{frame: nil} = page, answer, opts \\ []) do
    params =
      case answer do
        :accept -> %{"accept" => true}
        :dismiss -> %{"accept" => false}
        {:accept, text} when is_binary(text) -> %{"accept" => true, "promptText" => text}
        other -> raise ArgumentError, "invalid dialog answer #{inspect(other)}"
      end

    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    case do_call(page, "Page.handleJavaScriptDialog", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Presses a single named `key`, dispatching real `keyDown`/`keyUp` events.

  When `css` is a selector, the element is focused first; when `css` is `nil`, the
  key goes to the currently-focused element. Supported keys: `Enter`, `Tab`,
  `Escape`, `Backspace`, `Delete`, `ArrowUp`/`ArrowDown`/`ArrowLeft`/`ArrowRight`,
  `Home`, `End`.

  Returns `:ok`, `{:error, {:selector_not_found, css}}`, or
  `{:error, {:unknown_key, key}}`. Option: `:timeout` (default #{@evaluate_timeout}).
  """
  @spec press(t(), String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def press(%__MODULE__{} = page, css, key, opts \\ [])
      when (is_binary(css) or is_nil(css)) and is_binary(key) do
    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    with {:ok, fields} <- keymap(key),
         :ok <- maybe_focus(page, css, opts),
         {:ok, _} <-
           do_call(top(page), "Input.dispatchKeyEvent", Map.put(fields, "type", "keyDown"), timeout),
         {:ok, _} <-
           do_call(top(page), "Input.dispatchKeyEvent", Map.put(fields, "type", "keyUp"), timeout) do
      :ok
    end
  end

  # Same whitespace set as the locator's normalize-space() port.
  defp blank_text?(text), do: Regex.match?(~r/\A[ \t\r\n]*\z/, text)

  defp click_with_wait(page, locator, not_found, label, opts) do
    if Keyword.get(opts, :trusted, true) do
      with_wait(opts, fn -> trusted_mouse(page, locator, not_found, label, :click, opts) end)
    else
      with_wait(opts, fn -> synthetic_click(page, locator, not_found, opts) end)
    end
  end

  defp with_wait(opts, attempt) do
    result =
      case Keyword.get(opts, :wait, 0) do
        0 ->
          attempt.()

        wait when is_integer(wait) and wait > 0 ->
          retry_click(attempt, System.monotonic_time(:millisecond) + wait)

        other ->
          raise ArgumentError, "invalid :wait #{inspect(other)} (expected a non-negative integer)"
      end

    case result do
      :ok -> :ok
      {_phase, reason} -> {:error, reason}
    end
  end

  # Only :locate failures (nothing dispatched yet) are retried; after :dispatch the click
  # may have happened, and a retry could double-click.
  defp retry_click(attempt, deadline) do
    case attempt.() do
      {:locate, reason} = failure ->
        if retryable_locate?(reason) and remaining(deadline) > 0 do
          Process.sleep(min(@click_poll_interval, remaining(deadline)))
          retry_click(attempt, deadline)
        else
          failure
        end

      result ->
        result
    end
  end

  defp retryable_locate?({tag, _}) when tag in @retryable_locate, do: true

  defp retryable_locate?({:cdp_error, _method, %{"message" => message}}) do
    is_binary(message) and String.contains?(message, @context_missing)
  end

  defp retryable_locate?(_reason), do: false

  defp text_selector!(selector) when is_nil(selector) or is_binary(selector), do: selector

  defp text_selector!(other),
    do: raise(ArgumentError, "invalid :selector #{inspect(other)} (expected a CSS string)")

  # A descendant's normalized text is a substring of its ancestor's, so a subtree that
  # can't contain the target is skipped. The climb only accepts HTML ancestors (an SVG
  # <title>'s <svg> has a box but no .click()) and stops at display:none, so a hidden
  # copy can't borrow its wrapper's box.
  defp text_locator(text, selector) do
    """
    (function () {
      var norm = function (s) { return s.replace(/[ \\t\\r\\n]+/g, " ").replace(/^ | $/g, ""); };
      var target = norm(#{Jason.encode!(text)});
      var selector = #{Jason.encode!(selector)};
      var matches = [];
      var boxed = function (el) {
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };
      var visible = function (el) {
        return boxed(el) && (typeof el.checkVisibility !== "function" ||
          el.checkVisibility({visibilityProperty: true, opacityProperty: true}));
      };
      var walk = function (el) {
        if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT)$/.test(el.tagName.toUpperCase())) { return false; }
        var t = norm(el.textContent);
        if (t.indexOf(target) === -1) { return false; }
        var inner = false;
        for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
          if (walk(c)) { inner = true; }
        }
        if (inner) { return true; }
        if (t === target && (selector === null || el.matches(selector))) {
          matches.push(el);
          return true;
        }
        return false;
      };
      if (selector !== null) { document.createDocumentFragment().querySelector(selector); }
      if (!document.body) { return null; }
      for (var c = document.body.firstElementChild; c; c = c.nextElementSibling) { walk(c); }
      var hidden = function (el) { return getComputedStyle(el).display === "none"; };
      var resolve = function (m) {
        if (boxed(m) || (m instanceof HTMLElement && hidden(m))) { return m; }
        for (var el = m.parentElement; el && el !== document.body; el = el.parentElement) {
          if (hidden(el) || norm(el.textContent) !== target) { break; }
          if (el instanceof HTMLElement && (selector === null || el.matches(selector)) && boxed(el)) {
            return el;
          }
        }
        return m;
      };
      var targets = matches.map(resolve);
      for (var i = 0; i < targets.length; i++) { if (visible(targets[i])) { return targets[i]; } }
      for (var k = 0; k < targets.length; k++) { if (boxed(targets[k])) { return targets[k]; } }
      return targets.length > 0 ? targets[0] : null;
    })()
    """
  end

  # One evaluate locates and clicks, so only a never-found context or `false` proves
  # nothing ran; a torn-down context may be the click's own navigation.
  defp synthetic_click(page, locator, not_found, opts) do
    js = """
    (function () {
      var el = #{locator};
      if (!el) { return false; }
      if (typeof el.click === "function") { el.click(); }
      else { el.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window})); }
      return true;
    })()
    """

    case evaluate(page, js, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> {:locate, not_found}
      {:error, {:cdp_error, _, _} = reason} -> {synthetic_phase(reason), reason}
      {:error, reason} -> {:dispatch, reason}
    end
  end

  defp synthetic_phase({:cdp_error, _, %{"message" => msg}}) when is_binary(msg) do
    if String.contains?(msg, @context_not_found), do: :locate, else: :dispatch
  end

  defp synthetic_phase(_reason), do: :dispatch

  defp trusted_mouse(page, locator, not_found, label, action, opts) do
    js = """
    (function () {
      var el = #{locator};
      if (!el) { return {found: false}; }
      if (el.scrollIntoViewIfNeeded) { el.scrollIntoViewIfNeeded(); }
      else { el.scrollIntoView({block: "center", inline: "center"}); }
      var root = el.getRootNode();
      var probe = typeof root.elementFromPoint === "function" ? root : document;
      var owns = function (hit) {
        for (var n = hit; n; n = n.parentNode || n.host) { if (n === el) { return true; } }
        return false;
      };
      var rects = el.getClientRects();
      var inView = false;
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        var left = Math.max(r.left, 0), right = Math.min(r.right, window.innerWidth);
        var top = Math.max(r.top, 0), bottom = Math.min(r.bottom, window.innerHeight);
        if (right <= left || bottom <= top) { continue; }
        inView = true;
        var x = (left + right) / 2, y = (top + bottom) / 2;
        if (owns(probe.elementFromPoint(x, y))) { return {found: true, clickable: true, x: x, y: y}; }
      }
      return {found: true, clickable: false, obscured: inView};
    })()
    """

    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    case evaluate(page, js, opts) do
      {:ok, %{"found" => false}} ->
        {:locate, not_found}

      {:ok, %{"clickable" => false, "obscured" => true}} ->
        {:locate, {:obscured, label}}

      {:ok, %{"clickable" => false}} ->
        {:locate, {:not_clickable, label}}

      {:ok, %{"clickable" => true, "x" => x, "y" => y}} ->
        with {:ok, x, y} <- to_top(page, x, y, label, timeout),
             {:error, reason} <- dispatch_action(page, action, x, y, timeout) do
          {:dispatch, reason}
        end

      {:error, reason} ->
        {:locate, reason}
    end
  end

  defp dispatch_action(page, :click, x, y, timeout) do
    with :ok <- dispatch_mouse(page, "mousePressed", x, y, "left", 1, timeout) do
      dispatch_mouse(page, "mouseReleased", x, y, "left", 0, timeout)
    end
  end

  defp dispatch_action(page, :hover, x, y, timeout),
    do: dispatch_mouse(page, "mouseMoved", x, y, "none", 0, timeout)

  defp dispatch_mouse(page, type, x, y, button, buttons, timeout) do
    params = %{
      "type" => type,
      "x" => x,
      "y" => y,
      "button" => button,
      "buttons" => buttons,
      "clickCount" => if(type == "mouseMoved", do: 0, else: 1)
    }

    case do_call(top(page), "Input.dispatchMouseEvent", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp focus(page, css, opts) do
    selector = Jason.encode!(css)

    js = """
    (function () {
      var el = document.querySelector(#{selector});
      if (!el) { return false; }
      el.focus();
      return true;
    })()
    """

    case evaluate(page, js, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:selector_not_found, css}}
      {:error, _} = error -> error
    end
  end

  defp maybe_focus(_page, nil, _opts), do: :ok
  defp maybe_focus(page, css, opts), do: focus(page, css, opts)

  @doc """
  Captures a PNG screenshot.

  Returns `{:ok, data}` where `data` is the PNG bytes — or, when `:path` is
  given, the written file path (also a binary).

  Options: `:path` (write to file), `:full_page` (capture beyond the viewport,
  default `false`), `:timeout` (default 30_000).
  """
  @spec screenshot(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def screenshot(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @screenshot_timeout)

    params = maybe_full_page(%{"format" => "png"}, Keyword.get(opts, :full_page, false))

    with {:ok, %{"data" => base64}} <-
           do_call(page, "Page.captureScreenshot", params, timeout),
         {:ok, bytes} <- decode_base64(base64, :invalid_screenshot_data) do
      write_or_return(bytes, Keyword.get(opts, :path))
    end
  end

  @doc """
  Returns the cookies of the page's browser context as a list of CDP cookie maps:
  the page's own context for a page opened with `isolated: true`, otherwise the
  browser's default context, shared by every page that isn't isolated.

  Lazily enables the `Network` domain. Options: `:timeout` (default 10_000).
  """
  @spec cookies(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def cookies(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, %{"cookies" => cookies}} <-
           do_call(page, "Network.getAllCookies", %{}, timeout) do
      {:ok, cookies}
    end
  end

  @doc """
  Sets cookies in the page's browser context (see `cookies/2`). Each is a CDP
  `CookieParam` map — at least `"name"`, `"value"`, and a `"url"` or `"domain"`.
  Lazily enables `Network`. Options: `:timeout`.
  """
  @spec set_cookies(t(), [map()], keyword()) :: :ok | {:error, term()}
  def set_cookies(%__MODULE__{frame: nil} = page, cookies, opts \\ []) when is_list(cookies) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <-
           do_call(page, "Network.setCookies", %{"cookies" => cookies}, timeout) do
      :ok
    end
  end

  @doc """
  Clears the cookies of the page's browser context (see `cookies/2`). Lazily enables
  `Network`. Options: `:timeout`.
  """
  @spec clear_cookies(t(), keyword()) :: :ok | {:error, term()}
  def clear_cookies(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <- do_call(page, "Network.clearBrowserCookies", %{}, timeout) do
      :ok
    end
  end

  @doc """
  Starts observing network traffic, delivering CDP `Network` events to the calling
  process.

  Subscribes the caller to `:events` (default the request + response lifecycle),
  then enables the `Network` domain (idempotent). Each event arrives as
  `{:cdp_event, conn, method, params, session_id}` — handle them in a `handle_info`.
  Call `stop_observing_network/2` to unsubscribe.

  Start observing **before** navigating: requests already in flight when you call
  this are not captured. Delivery is scoped to this page's session, so on a
  `:session`-transport connection you receive only this page's `Network` events,
  not those of other pages sharing the socket. Observing several pages from one
  process accumulates — you receive each observed page's events, told apart by the
  `session_id` element.

  Options:
    * `:events` — `Network.*` method names (default request + response lifecycle)
    * `:timeout` — ms for the enable call (default 10_000)
  """
  @spec observe_network(t(), keyword()) :: :ok | {:error, term()}
  def observe_network(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    methods = Keyword.get(opts, :events, @network_events)

    # Subscribe BEFORE enabling so an event emitted the instant the domain turns on
    # can't slip through before the caller is registered (mirrors navigate/3's
    # subscribe-before-trigger).
    with :ok <- subscribe_each(page.conn, methods, timeout, page.session_id),
         :ok <- ensure_network(page, timeout) do
      :ok
    else
      {:error, _} = error ->
        # Enable failed — undo the subscriptions we just added. This drops every
        # method in `methods`; if the caller had independently subscribed to one of
        # them beforehand, that subscription goes too (an accepted edge case —
        # observe_network owns the lifecycle of the methods it is given).
        unsubscribe_each(page.conn, methods, page.session_id)
        error
    end
  end

  @doc """
  Stops observing — unsubscribes the caller from the network `:events`. Leaves the
  `Network` domain enabled.

  Pass the **same** `:events` you gave `observe_network/2`. Both default to the
  request + response lifecycle, but if you observed with a custom list you must
  repeat it here — otherwise the original subscriptions are never removed and the
  caller keeps receiving those events.
  """
  @spec stop_observing_network(t(), keyword()) :: :ok
  def stop_observing_network(%__MODULE__{frame: nil} = page, opts \\ []) do
    unsubscribe_each(page.conn, Keyword.get(opts, :events, @network_events), page.session_id)
  end

  @doc """
  Starts observing the page's console, delivering `console.*` calls and uncaught
  exceptions to the calling process — the page's own and its iframes', cross-site
  (out-of-process) ones included.

  Subscribes the caller to `:events`, by default `Runtime.consoleAPICalled` (params
  carry `"type"` such as `"log"` or `"error"`, the `"args"` as `Runtime.RemoteObject`s
  and a `"stackTrace"`) and `Runtime.exceptionThrown` (params carry
  `"exceptionDetails"`). Each event arrives as
  `{:cdp_event, conn, method, params, session_id}` — handle them in a `handle_info`.
  Call `stop_observing_console/2` to unsubscribe.

  Start observing **before** navigating: messages logged before the call are not
  delivered. Same-process iframes log into the page's session, told apart by
  `"executionContextId"`. A cross-site iframe's events carry its own session id: the
  page's `CDPEx.Fetch` process auto-attaches each such iframe and enables `Runtime`
  there before it runs. On a `:session` page it passes the iframe's events on, so they
  can arrive out of order with the page's own; only the two methods above come from
  those iframes. Delivery is scoped to this page, as with `observe_network/2`.

  Options:
    * `:events` — `Runtime.*` method names (default the two above)
    * `:timeout` — ms for the subscriptions and the iframe setup (default 10_000)
  """
  @spec observe_console(t(), keyword()) :: :ok | {:error, term()}
  def observe_console(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    methods = Keyword.get(opts, :events, @console_events)

    with :ok <- subscribe_each(page.conn, methods, timeout, page.session_id),
         :ok <- Browser.observe_console(page.browser, page, methods, timeout) do
      :ok
    else
      {:error, _} = error ->
        unsubscribe_each(page.conn, methods, page.session_id)
        error
    end
  end

  @doc """
  Stops observing the console — unsubscribes the caller from the console `:events`, the
  iframes' included. Pass the **same** `:events` you gave `observe_console/2`.
  """
  @spec stop_observing_console(t(), keyword()) :: :ok
  def stop_observing_console(%__MODULE__{frame: nil} = page, opts \\ []) do
    unsubscribe_each(page.conn, Keyword.get(opts, :events, @console_events), page.session_id)
    _ = Browser.unobserve_console(page.browser, page, @command_timeout)
    :ok
  end

  @doc """
  Returns a response's body by its `request_id` (from a `Network.responseReceived`
  event), via `Network.getResponseBody`.

  Returns `{:ok, body}` (decoding base64 when Chrome sends it that way) or
  `{:error, reason}`. The `Network` domain must have been enabled (e.g. via
  `observe_network/2`) **when the request was captured** — unlike the other Network
  ops this does not lazily enable it, since enabling now can't recover a past body.
  If it wasn't enabled, the call surfaces as
  `{:error, {:cdp_error, "Network.getResponseBody", _}}`.

  The body is only retrievable once the request has finished loading. Calling this in
  the window between `Network.responseReceived` (what `wait_for_response/3` resolves on)
  and `Network.loadingFinished` can return
  `{:error, {:cdp_error, "Network.getResponseBody", %{"code" => -32000}}}`
  ("No data found …"). Wait for the network to settle (e.g. `wait_for_network_idle/2`)
  before reading, or retry on that transient error.

  Options: `:timeout` (default 10_000).
  """
  @spec response_body(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def response_body(%__MODULE__{frame: nil} = page, request_id, opts \\ [])
      when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case do_call(page, "Network.getResponseBody", %{"requestId" => request_id}, timeout) do
      {:ok, %{"body" => body, "base64Encoded" => true}} ->
        decode_base64(body, :invalid_response_body)

      {:ok, %{"body" => body}} ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Blocks until a network response whose URL matches `matcher` arrives, or `timeout`.

  Useful after a `click/3` (or other in-page action) that triggers an XHR/`fetch`:
  wait for the specific response, then read it with `response_body/3` (the returned
  params carry the `"requestId"`). Pass the action as `:trigger`:

      Page.wait_for_response(page, "/api/search",
        trigger: fn -> Page.click(page, "#search") end
      )

  `matcher` selects on the response URL and may be:

    * a **function** `(url :: String.t() -> boolean())`,
    * a **`Regex`** (matched against the URL), or
    * a **binary** substring (matched with `String.contains?/2`).

  A function `matcher` runs inside the connection process for each candidate
  response, so keep it fast and side-effect-free (a slow matcher stalls the
  socket, and every page on a `:session`-transport connection with it).

  Returns `{:ok, params}` — the full `Network.responseReceived` params (HTTP status
  under `params["response"]["status"]`, request id under `params["requestId"]`) — or
  `{:error, :timeout}` if nothing matched in time, or `{:error, reason}` if the
  connection drops (or, on a `:session` page, `{:error, {:session_closed, sid}}` if
  the session detaches). Lazily enables the `Network` domain. Only responses
  observed **after** this call are considered.

  ## Triggering the request

  With `:trigger`, the wait is registered (and `Network` enabled) first, then
  `trigger` runs in the calling process, then the call waits for the match, so a
  response that arrives while `trigger` is still running, however fast, is caught.
  A `{:error, _}` from `trigger` is returned without waiting, unless the response
  already matched while it ran (then the match wins); any other return value starts
  the wait. A raise, throw or exit in `trigger` propagates, and the wait is cancelled
  first. The outcome is delivered to the calling process's mailbox while `trigger`
  runs, so `trigger` must not consume messages it doesn't own. If the calling process
  is killed mid-call, the connection drops the wait at once.

  `:timeout` bounds the enable and the wait, and `trigger`'s run time counts
  against it, but `trigger` runs in the calling process and is not interrupted.
  One that runs past `:timeout` makes the call return when it finishes: with the
  response if one matched before the deadline, else `{:error, :timeout}`. Give
  `trigger`'s own operations shorter timeouts than the overall one. If the enable
  leaves no budget, `trigger` doesn't run, and the call returns an outcome that
  already arrived (a match, a detach, a dropped connection), else `{:error, :timeout}`.

  Without `:trigger` the call blocks from the start, so the request has to come
  from another process (e.g. the wait in a `Task`, then the click). That races: a
  response that lands before the wait is registered, including during its
  `Network.enable`, is missed and the call runs to `:timeout`, and on a `:session`
  page so is a detach in that window. Prefer `:trigger`.

  ## The body with the response (`body: true`)

  `body: true` also waits for the matched request to finish loading
  (`Network.loadingFinished`) and returns its body, decoded, under `"body"` in the
  params. `response_body/3` called right after the response alone races that event:
  Chrome answers `"No data found"` until the body has fully arrived. A request that
  fails after its response returns `{:error, {:loading_failed, error_text}}` (Chrome's
  `net::ERR_*` text); one that never finishes (a stream, `EventSource`) runs to
  `:timeout`, which covers the finish and the body read too.

  > #### Returns `{:ok, params}`, not a bare `:ok` {: .info}
  >
  > Unlike `wait_for_navigation/2` / `wait_for_selector/3` / `wait_for_network_idle/2`
  > (which return `:ok`), this returns the matched event — match on `{:ok, params}`.

  Options:
    * `:trigger` — a 0-arity function that starts the request (see above)
    * `:body` — `true` waits for the request to finish and returns its body too
      (see above) (default `false`)
    * `:timeout` — ceiling in ms; a running `trigger` is not interrupted (see
      above) (default 30_000)
  """
  @spec wait_for_response(t(), (String.t() -> boolean()) | Regex.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_response(%__MODULE__{frame: nil} = page, matcher, opts \\ []) do
    trigger = trigger_opt(Keyword.get(opts, :trigger))
    body? = response_body_opt(Keyword.get(opts, :body, false))
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @navigate_timeout)
    predicate = response_url_predicate(matcher)

    if body? do
      await_response_with_body(page, predicate, trigger, deadline)
    else
      await_matched_response(page, predicate, trigger, deadline)
    end
  end

  defp await_matched_response(page, predicate, nil, deadline),
    do: await_response(page, predicate, deadline)

  defp await_matched_response(page, predicate, trigger, deadline),
    do: await_triggered_response(page, predicate, trigger, deadline)

  defp response_body_opt(value) when is_boolean(value), do: value

  defp response_body_opt(other),
    do: raise(ArgumentError, "invalid :body #{inspect(other)} (expected a boolean)")

  # body: true. The matched request's requestId isn't known until its response, and its
  # loadingFinished can follow at once, before a second wait could be registered. So the
  # finish waiter is registered up front, and the response matcher records the id in a
  # table the finish matcher reads: both run in the connection process, in event order,
  # so the id is there before that request's loadingFinished is matched.
  defp await_response_with_body(page, predicate, trigger, deadline) do
    table = :ets.new(:cdp_ex_wait_for_response, [:set, :public])

    recording = fn params ->
      predicate.(params) and record_request_id(table, params["requestId"])
    end

    case Connection.await_event_async(page.conn, &finished?(table, &1), remaining(deadline),
           session_id: page.session_id
         ) do
      {:ok, ref} ->
        mon = Process.monitor(page.conn)

        try do
          with {:ok, params} <- await_matched_response(page, recording, trigger, deadline),
               :ok <- await_finished(ref, mon, deadline),
               {:ok, body} <-
                 response_body(page, params["requestId"], timeout: max(remaining(deadline), 1)) do
            {:ok, Map.put(params, "body", body)}
          end
        after
          Process.demonitor(mon, [:flush])
          Connection.cancel_await(page.conn, ref)
          :ets.delete(table)
        end

      {:error, reason} ->
        :ets.delete(table)
        await_result({:error, reason})
    end
  end

  defp record_request_id(table, request_id) when is_binary(request_id) do
    :ets.insert_new(table, {:request_id, request_id})
    true
  end

  defp record_request_id(_table, _request_id), do: false

  # Network.loadingFinished (encodedDataLength, no dataLength: not dataReceived) or
  # Network.loadingFailed (errorText) of the recorded request.
  defp finished?(table, %{"requestId" => id} = params) when is_binary(id) do
    finish_event?(params) and :ets.lookup(table, :request_id) == [{:request_id, id}]
  end

  defp finished?(_table, _params), do: false

  defp finish_event?(params) do
    not Map.has_key?(params, "response") and not Map.has_key?(params, "dataLength") and
      (Map.has_key?(params, "encodedDataLength") or Map.has_key?(params, "errorText"))
  end

  defp await_finished(ref, mon, deadline) do
    case receive_response(ref, mon, deadline) do
      {:ok, %{"errorText" => error_text}} -> {:error, {:loading_failed, error_text}}
      {:ok, _finished} -> :ok
      {:error, _} = error -> error
    end
  end

  defp trigger_opt(nil), do: nil
  defp trigger_opt(fun) when is_function(fun, 0), do: fun

  defp trigger_opt(other) do
    raise ArgumentError, "invalid :trigger #{inspect(other)} (expected a 0-arity function)"
  end

  # One deadline for the whole call so :timeout is a true overall ceiling: the lazy
  # Network.enable and the await draw from the same budget.
  defp await_response(page, predicate, deadline) do
    with :ok <- enable_network_within(page, deadline) do
      case Connection.await_event(page.conn, predicate, remaining(deadline),
             session_id: page.session_id
           ) do
        {:ok, params} -> {:ok, params}
        {:error, {:timeout, :await_event}} -> {:error, :timeout}
        {:error, _} = error -> error
      end
    end
  end

  # The waiter is registered before Network.enable, not after, so a detach during
  # the enable fails it too: Connection fails a session's waiters on its detach.
  defp await_triggered_response(page, predicate, trigger, deadline) do
    case Connection.await_event_async(page.conn, predicate, remaining(deadline),
           session_id: page.session_id
         ) do
      {:ok, ref} ->
        mon = Process.monitor(page.conn)

        try do
          case enable_network_within(page, deadline) do
            :ok -> trigger_and_wait(ref, mon, trigger, deadline)
            {:error, :timeout} -> receive_response(ref, mon, deadline)
            {:error, _} = error -> error
          end
        after
          Process.demonitor(mon, [:flush])
          Connection.cancel_await(page.conn, ref)
        end

      {:error, reason} ->
        await_result({:error, reason})
    end
  end

  # A trigger usually has side effects (a click, a submit), so don't fire one with
  # no budget left. With the budget spent, receive_response/3 only reports an
  # outcome already in the mailbox (a match, a detach, a closed socket), else times out.
  defp trigger_and_wait(ref, mon, trigger, deadline) do
    if remaining(deadline) == 0 do
      receive_response(ref, mon, deadline)
    else
      case run_trigger(trigger) do
        :ok -> receive_response(ref, mon, deadline)
        {:error, _} = error -> matched_already(ref, error)
      end
    end
  end

  defp run_trigger(trigger) do
    case trigger.() do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp matched_already(ref, error) do
    receive do
      {:cdp_await, ^ref, {:ok, _} = matched} -> matched
    after
      0 -> error
    end
  end

  defp receive_response(ref, mon, deadline) do
    receive do
      {:cdp_await, ^ref, result} -> await_result(result)
      {:DOWN, ^mon, :process, _conn, reason} -> {:error, down_reason(reason)}
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp await_result({:error, {:timeout, :await_event}}), do: {:error, :timeout}
  defp await_result(result), do: result

  # Build a params-predicate from the public URL matcher (function / Regex / substring),
  # always guarding that the event actually carries a response URL — so it fires only on
  # a Network.responseReceived, never a request or lifecycle event.
  defp response_url_predicate(fun) when is_function(fun, 1) do
    fn params -> match_response_url(params, fun) end
  end

  defp response_url_predicate(%Regex{} = regex) do
    fn params -> match_response_url(params, &Regex.match?(regex, &1)) end
  end

  defp response_url_predicate(substring) when is_binary(substring) do
    fn params -> match_response_url(params, &String.contains?(&1, substring)) end
  end

  defp match_response_url(%{"response" => %{"url" => url}}, fun) when is_binary(url), do: fun.(url)
  defp match_response_url(_params, _fun), do: false

  @doc """
  Waits for a download started by the page or one of its iframes, and returns it once
  Chrome has written the whole file.

      {:ok, %{path: path, suggested_filename: "report.csv"}} =
        Page.wait_for_download(page,
          trigger: fn -> Page.click(page, "#export") end,
          path: "/data/report.csv"
        )

  A launched browser saves downloads in its profile dir, not in the user's Downloads
  folder (Chrome's default), each file named by Chrome's id for the download. With
  `:path` the file is moved there once complete; its parent dir must exist. Without it,
  `path` is the file in the profile dir, which stays until the browser stops: move or
  delete it when done, or a long-lived pooled browser accumulates them. Downloads nobody
  waits for are saved there too.

  Returns `{:ok, %{path, suggested_filename, url, size}}`: `suggested_filename` is the
  name from the server's `Content-Disposition` or the link's `download` attribute, `url`
  the download's URL (a `blob:` or `data:` one for a file the page built), `size` the
  bytes written. Errors:

    * `{:error, :timeout}` — no download of this page completed in time. One still in
      progress is canceled.
    * `{:error, {:download_canceled, url}}` — Chrome canceled it, e.g. the connection
      dropped mid-file. Chrome gives no reason.
    * `{:error, {:write_failed, posix}}` — moving it to `:path` failed. The file stays in
      the profile dir.
    * `{:error, {:unsupported_with_connect, :downloads}}` — a browser from
      `CDPEx.connect/2`, whose Chrome writes files on its own host under its own settings.

  The first download of the page that starts after the wait is registered is the one
  returned. One started by a frame nested inside a cross-site iframe isn't seen as the
  page's.

  ## Triggering the download

  `:trigger` works as in `wait_for_response/3`: the wait is registered first, then
  `trigger` runs in the calling process, so a download that starts at once is caught. A
  `{:error, _}` from `trigger` is returned without waiting, unless the download has
  already started; a raise, throw or exit propagates, and the wait is cancelled first.

  Navigating to a file's URL returns `{:error, {:navigate, "net::ERR_ABORTED"}}`, often
  before Chrome reports the download: it ends the navigation as it turns into a download.
  Ignore that result in the trigger:

      Page.wait_for_download(page,
        trigger: fn ->
          _ = Page.navigate(page, file_url)
          :ok
        end
      )

  Without `:trigger` the download has to start from another process, and one that starts
  before the wait is registered is missed.

  Options:
    * `:trigger` — a 0-arity function that starts the download (see above)
    * `:path` — where to move the finished file (default: leave it in the profile dir)
    * `:timeout` — ceiling in ms for the whole download; a running `trigger` is not
      interrupted (default 30_000)
  """
  @spec wait_for_download(t(), keyword()) :: {:ok, download()} | {:error, term()}
  def wait_for_download(%__MODULE__{frame: nil} = page, opts \\ []) do
    trigger = trigger_opt(Keyword.get(opts, :trigger))
    path = download_path_opt(Keyword.get(opts, :path))
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @navigate_timeout)

    with {:ok, downloads} <- Browser.downloads(page.browser, page, max(remaining(deadline), 1)),
         {:ok, download} <- await_download(page, downloads, trigger, deadline) do
      place_download(download, path)
    end
  end

  defp download_path_opt(path) when is_nil(path) or is_binary(path), do: path

  defp download_path_opt(other),
    do: raise(ArgumentError, "invalid :path #{inspect(other)} (expected a string)")

  # The Browser.download* events arrive on the browser connection, for every page, so a
  # helper process subscribes there and picks out this page's download (download_owner?/4).
  # It owns the download until it replies: it cancels one in progress when the wait ends
  # without it (timeout, a failed or raising trigger, the caller's death).
  defp await_download(page, downloads, trigger, deadline) do
    caller = self()
    tag = make_ref()

    {helper, mon} =
      spawn_monitor(fn ->
        ProcessLabel.set({:cdp_download_wait, page.target_id})
        download_helper(caller, tag, page, downloads, deadline)
      end)

    try do
      case receive_download(tag, mon, deadline) do
        :ready -> trigger_download(trigger, tag, mon, deadline)
        {:error, _} = error -> error
      end
    after
      send(helper, {tag, :stop})
      Process.demonitor(mon, [:flush])
      flush_tagged(tag)
    end
  end

  defp trigger_download(trigger, tag, mon, deadline) do
    case run_download_trigger(trigger, tag, deadline) do
      :ok -> receive_download(tag, mon, deadline)
      {:error, _} = error -> error
    end
  end

  # As in trigger_and_wait/4: no budget left, no trigger (it has side effects).
  defp run_download_trigger(nil, _tag, _deadline), do: :ok

  defp run_download_trigger(trigger, tag, deadline) do
    if remaining(deadline) == 0,
      do: :ok,
      else: trigger |> run_trigger() |> started_already(tag)
  end

  # A trigger's error doesn't end the wait for a download that has already started.
  defp started_already(:ok, _tag), do: :ok

  defp started_already({:error, _} = error, tag) do
    receive do
      {^tag, :started} -> :ok
    after
      0 -> error
    end
  end

  # :ready once the helper is subscribed, then its result. The helper bounds its own wait
  # by the deadline; the grace only catches one that never replies.
  defp receive_download(tag, mon, deadline) do
    receive do
      {^tag, :ready} -> :ready
      {^tag, {:done, result}} -> result
      {:DOWN, ^mon, :process, _helper, reason} -> {:error, {:download_wait_failed, reason}}
    after
      remaining(deadline) + @helper_grace -> {:error, {:download_wait_failed, :timeout}}
    end
  end

  defp flush_tagged(tag) do
    receive do
      {^tag, _} -> flush_tagged(tag)
    after
      0 -> :ok
    end
  end

  defp download_helper(caller, tag, page, downloads, deadline) do
    caller_mon = Process.monitor(caller)
    conn_mon = Process.monitor(downloads.conn)
    mons = {caller_mon, conn_mon}

    case subscribe_each(downloads.conn, @download_events, max(remaining(deadline), 1), nil) do
      :ok ->
        send(caller, {tag, :ready})

        reply_download(
          caller,
          tag,
          await_download_start(caller, tag, page, downloads, mons, deadline)
        )

      {:error, _} = error ->
        reply_download(caller, tag, error)
    end
  end

  defp reply_download(_caller, _tag, :stopped), do: :ok
  defp reply_download(caller, tag, result), do: send(caller, {tag, {:done, result}})

  defp await_download_start(caller, tag, page, downloads, {caller_mon, conn_mon} = mons, deadline) do
    receive do
      {:cdp_event, _conn, @download_will_begin, %{"guid" => guid, "frameId" => frame_id} = params,
       _sid} ->
        if download_owner?(page, downloads.conn, frame_id, deadline) do
          send(caller, {tag, :started})
          await_download_end(tag, downloads, guid, params, mons, deadline)
        else
          await_download_start(caller, tag, page, downloads, mons, deadline)
        end

      {^tag, :stop} ->
        :stopped

      {:DOWN, ^caller_mon, :process, _, _} ->
        :stopped

      {:DOWN, ^conn_mon, :process, _, reason} ->
        {:error, down_reason(reason)}

      {:cdp_event, _conn, _method, _params, _sid} ->
        await_download_start(caller, tag, page, downloads, mons, deadline)
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp await_download_end(tag, downloads, guid, began, {caller_mon, conn_mon} = mons, deadline) do
    receive do
      {:cdp_event, _conn, @download_progress, %{"guid" => ^guid, "state" => "completed"} = params,
       _sid} ->
        {:ok,
         %{
           path: Map.get(params, "filePath") || Path.join(downloads.dir, guid),
           suggested_filename: began["suggestedFilename"],
           url: began["url"],
           size: params["receivedBytes"]
         }}

      {:cdp_event, _conn, @download_progress, %{"guid" => ^guid, "state" => "canceled"}, _sid} ->
        {:error, {:download_canceled, began["url"]}}

      {^tag, :stop} ->
        cancel_download(downloads, guid)
        :stopped

      {:DOWN, ^caller_mon, :process, _, _} ->
        cancel_download(downloads, guid)
        :stopped

      {:DOWN, ^conn_mon, :process, _, reason} ->
        {:error, down_reason(reason)}

      {:cdp_event, _conn, _method, _params, _sid} ->
        await_download_end(tag, downloads, guid, began, mons, deadline)
    after
      remaining(deadline) ->
        cancel_download(downloads, guid)
        {:error, :timeout}
    end
  end

  # Chrome deletes the partial file of a canceled download.
  defp cancel_download(%{conn: conn, context_id: context_id}, guid) do
    params = put_present(%{"guid" => guid}, "browserContextId", context_id)
    _ = Connection.call(conn, "Browser.cancelDownload", params, @probe_timeout)
    :ok
  end

  # The event names the frame that started the download: the page's main frame (its
  # target id), a same-process iframe (in the page's frame tree), or a cross-site iframe,
  # whose own target leads back to the page through parentId. A frame inside a cross-site
  # iframe is in that iframe's frame tree only, which isn't searched.
  defp download_owner?(%__MODULE__{target_id: frame_id}, _conn, frame_id, _deadline), do: true

  defp download_owner?(page, conn, frame_id, deadline) do
    in_frame_tree?(page, frame_id, deadline) or
      iframe_of?(page.target_id, conn, frame_id, deadline, @max_iframe_depth)
  end

  defp in_frame_tree?(page, frame_id, deadline) do
    case do_call(page, "Page.getFrameTree", %{}, max(remaining(deadline), 1)) do
      {:ok, %{"frameTree" => tree}} -> frame_id in frame_ids(tree)
      {:error, _} -> false
    end
  end

  defp frame_ids(%{"frame" => %{"id" => id}} = tree),
    do: [id | Enum.flat_map(Map.get(tree, "childFrames", []), &frame_ids/1)]

  defp frame_ids(_tree), do: []

  defp iframe_of?(_target_id, _conn, _frame_id, _deadline, 0), do: false

  defp iframe_of?(target_id, conn, frame_id, deadline, depth) do
    case Connection.call(
           conn,
           "Target.getTargetInfo",
           %{"targetId" => frame_id},
           max(remaining(deadline), 1)
         ) do
      {:ok, %{"targetInfo" => %{"type" => "iframe", "parentId" => ^target_id}}} ->
        true

      {:ok, %{"targetInfo" => %{"type" => "iframe", "parentId" => parent}}}
      when is_binary(parent) ->
        iframe_of?(target_id, conn, parent, deadline, depth - 1)

      _other ->
        false
    end
  end

  defp place_download(download, nil), do: {:ok, download}

  defp place_download(%{path: from} = download, to) do
    case move_file(from, to) do
      :ok -> {:ok, %{download | path: to}}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  # A rename can't cross file systems (the profile dir is in the temp dir): copy instead.
  defp move_file(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with :ok <- File.cp(from, to), do: File.rm(from)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Blocks until the network has been idle — at most `:max_inflight` in-flight requests —
  for `:idle_time` ms continuously, or `timeout`.

  The Puppeteer "networkidle" primitive: use it after a `click/3` (or other action)
  that kicks off XHR/`fetch` hydration to wait for the page to settle. Idleness is
  measured **from the call onward** — requests already in flight when you call are not
  counted — so call it right after triggering the work.

  Returns `:ok` once idle, `{:error, :timeout}` if it never settles within `timeout`
  (e.g. a streaming / SSE / long-poll connection that never closes), or
  `{:error, reason}` if the connection drops. Lazily enables the `Network` domain.

  The idle wait runs in a short-lived helper process with its own subscription, so it
  composes safely with `observe_network/2` on the same page — the caller's subscription
  and any buffered events are left untouched. A normal connection drop surfaces as
  `{:error, :noproc}` / `{:error, {:ws_closed, _}}` (a `:session` page's detach as
  `{:error, {:session_closed, sid}}`); only an abnormal crash of that
  internal helper returns `{:error, {:idle_wait_failed, reason}}`.

  Options:
    * `:idle_time` — ms of continuous idleness required (default 500)
    * `:max_inflight` — in-flight requests still considered idle (default 0; 2 is
      Puppeteer's `networkidle2`)
    * `:timeout` — overall ceiling in ms (default 30_000)
  """
  @spec wait_for_network_idle(t(), keyword()) :: :ok | {:error, term()}
  def wait_for_network_idle(%__MODULE__{frame: nil} = page, opts \\ []) do
    idle_time = Keyword.get(opts, :idle_time, 500)
    max_inflight = Keyword.get(opts, :max_inflight, 0)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @navigate_timeout)

    run_in_helper(
      fn -> run_network_idle(page, idle_time, max_inflight, deadline) end,
      :idle_wait_failed,
      deadline,
      {:cdp_page_helper, :idle_wait, page.target_id}
    )
  end

  # The idle-wait helper body (runs in the spawned process). Subscribes BEFORE enabling so a
  # request that starts the instant the domain turns on is counted (mirrors observe_network/2),
  # then tracks in-flight requests until the network stays idle. `deadline` is an absolute
  # monotonic time computed by the caller, so one deadline spans enable + the idle wait and
  # :timeout is a true overall ceiling. Returns :ok | {:error, reason}. No try/after teardown:
  # the helper's subscriptions are pruned by Connection on its :DOWN and its idle-tick timers
  # die with it (an enable failure likewise just exits the helper and is auto-pruned).
  defp run_network_idle(page, idle_time, max_inflight, deadline) do
    methods = watched(page, @idle_events)

    with :ok <- subscribe_each(page.conn, methods, remaining(deadline), page.session_id),
         :ok <- enable_network_within(page, deadline) do
      Enum.each(@idle_events, &drain_events(page.conn, &1))

      # Subscribed is not yet counting: the drain above discards whatever arrived
      # while enabling, so a request that started before this point is invisible
      # to the wait. Announce the boundary — it is the only way a caller (or a
      # test) can know the helper is watching rather than still setting up.
      Telemetry.network_idle_watching(page.session_id)

      ref = Process.monitor(page.conn)

      ctx = %{
        conn: page.conn,
        sid: page.session_id,
        max_inflight: max_inflight,
        idle_time: idle_time,
        mon: ref,
        deadline: deadline
      }

      # Idle from the call onward: arm immediately (0 in-flight <= max_inflight).
      case await_network_idle(ctx, %{}, arm_idle(idle_time)) do
        :idle -> :ok
        :timeout -> {:error, :timeout}
        {:down, reason} -> {:error, down_reason(reason)}
      end
    end
  end

  # Track in-flight requests in a map keyed by request id, used as a set (`inflight`), not
  # a counter: requestWillBeSent adds, loadingFinished/Failed removes; responseReceived is
  # ignored. A set (vs a +1/−1 delta) is robust to the two ways CDP breaks a naive counter:
  #   * a redirect re-emits requestWillBeSent for the SAME id (a no-op re-add) yet fires
  #     only one terminal event, and
  #   * a request that started BEFORE this call (its requestWillBeSent never seen) fires a
  #     terminal event whose id isn't tracked (a no-op remove) — so it can't clear a live
  #     request's slot and trigger a false idle.
  # The idle timer is armed while the size is at/below the threshold and cancelled above;
  # when the live timer fires, the network stayed idle the whole window. Scoped to this
  # page's session (`^sid`); the connection dying or the overall deadline ends it. (A plain
  # map, not MapSet, keeps Dialyzer happy with this unspecced recursive helper.)
  defp await_network_idle(
         %{conn: conn, sid: sid, max_inflight: max_inflight, mon: mon, deadline: deadline} = ctx,
         inflight,
         {timer, tag} = idle
       ) do
    receive do
      {:cdp_event, ^conn, @request_will_be_sent, %{"requestId" => id}, ^sid} ->
        inflight = Map.put(inflight, id, true)
        idle = if map_size(inflight) > max_inflight, do: disarm_idle(idle), else: idle
        await_network_idle(ctx, inflight, idle)

      {:cdp_event, ^conn, method, %{"requestId" => id}, ^sid}
      when method in [@loading_finished, @loading_failed] ->
        inflight = Map.delete(inflight, id)

        idle =
          if map_size(inflight) <= max_inflight and timer == nil,
            do: arm_idle(ctx.idle_time),
            else: idle

        await_network_idle(ctx, inflight, idle)

      {:cdp_event, ^conn, @target_detached, %{"sessionId" => ^sid}, _parent} ->
        _ = disarm_idle(idle)
        {:down, {:session_closed, sid}}

      {:cdp_event, ^conn, _method, _params, _other_sid} ->
        # Another session's event on a shared :session connection — ignore.
        await_network_idle(ctx, inflight, idle)

      {:idle_tick, ^tag} ->
        :idle

      {:idle_tick, _stale} ->
        # A cancelled timer that had already fired — ignore.
        await_network_idle(ctx, inflight, idle)

      {:DOWN, ^mon, :process, ^conn, reason} ->
        _ = disarm_idle(idle)
        {:down, reason}
    after
      remaining(deadline) ->
        # Exact deadline-vs-DOWN tie: prefer a just-landed {:DOWN} or detach over a
        # stale timeout.
        receive do
          {:DOWN, ^mon, :process, ^conn, reason} ->
            _ = disarm_idle(idle)
            {:down, reason}

          {:cdp_event, ^conn, @target_detached, %{"sessionId" => ^sid}, _parent} ->
            _ = disarm_idle(idle)
            {:down, {:session_closed, sid}}
        after
          0 ->
            _ = disarm_idle(idle)
            :timeout
        end
    end
  end

  # A ref-tagged one-shot timer; the tag identifies *this* arming, so a stale fire from a
  # cancelled-but-already-delivered timer is ignored by the receive. A non-positive
  # idle_time is clamped to 0 (Process.send_after would raise on a negative).
  defp arm_idle(idle_time) do
    tag = make_ref()
    {Process.send_after(self(), {:idle_tick, tag}, max(idle_time, 0)), tag}
  end

  # Cancel the idle timer and return the disarmed state ({nil, nil}); idempotent, so it is
  # safe on a teardown path or when already disarmed.
  defp disarm_idle({nil, _tag}), do: {nil, nil}

  defp disarm_idle({timer, _tag}) do
    _ = Process.cancel_timer(timer)
    {nil, nil}
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  Enables request interception: pauses matching requests and delivers a
  `Fetch.requestPaused` event to the calling process for each one. You must then
  resolve **every** paused request with `continue_request/3`, `fulfill_request/3`,
  or `fail_request/3` (keyed by its `"requestId"`) — an unresolved request stalls
  the page.

  Each pause arrives as `{:cdp_event, conn, "Fetch.requestPaused", params, session_id}`;
  handle it in a `handle_info`. Interception is armed before this returns, so no
  paused request is missed.

  > #### Drive interception from one long-lived process {: .info}
  >
  > The calling process becomes the page's **interception owner**: the pauses are
  > sent to it, so handle them, and call `disable_request_interception/2`, from that
  > process. If it exits without disabling, the page's interception is released
  > automatically, so a crashed or forgetful caller can't leave it bricked (every
  > request paused with no resolver). While interception is enabled you must still
  > resolve every pause.

  Interception covers the page's own frames. A cross-site iframe runs as its own
  target in Chrome: its requests are let through (blocked types are still blocked,
  and a login is still answered there), not sent to you.

  Works on `:dedicated` and `:session` pages. On a `:session` page the pauses carry
  its session id, so one process can intercept several pages of a browser and tell
  them apart; disabling one leaves the others. When the page closes, its
  interception ends with it. Re-enabling interception on a page that already has it
  returns `{:error, :already_intercepting}`.

  Combines with `authenticate/4` and a credentialed `:proxy` on the same page, in
  either order. Chrome only raises a login challenge for a paused request, so with
  login on every request is paused: the library answers the challenges and lets
  through the requests outside `:patterns`, and you still receive only the pauses
  that match them. Each request then round-trips through the library, which costs
  some time on resource-heavy pages.

  Options:
    * `:patterns` — CDP `RequestPattern`s (default `[%{"urlPattern" => "*"}]`, all
      requests): maps with optional `"urlPattern"` (`*` matches any run of
      characters, `?` one, `\\` escapes), `"resourceType"` (`"Image"`, `"Script"`,
      ...) and `"requestStage"` (`"Request"`, the default, or `"Response"`). Atom
      keys are accepted. A malformed list returns
      `{:error, {:invalid_args, {:patterns, value}}}`.
    * `:timeout` — ms for the CDP calls (default 10_000)
  """
  @spec enable_request_interception(t(), keyword()) :: :ok | {:error, term()}
  def enable_request_interception(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    raw = Keyword.get(opts, :patterns, [%{"urlPattern" => "*"}])

    with {:ok, patterns} <- normalize_patterns(raw) do
      case Browser.intercept(page.browser, page, patterns, timeout) do
        {:error, {:timeout, _}} = error ->
          # The Browser request timed out, but the Fetch owner may still arm it: release
          # best-effort so the page doesn't stay intercepted by a caller told it failed.
          _ = Browser.release_interception(page.browser, page, timeout)
          error

        result ->
          result
      end
    end
  end

  @doc """
  Disables request interception and lets through any request still paused at the
  library. With `authenticate/4` or a credentialed `:proxy` on the page, login keeps
  working. Resolve the pauses you already received first.

  Call this from the process that called `enable_request_interception/2`. A page
  with no interception returns `:ok`.
  """
  @spec disable_request_interception(t(), keyword()) :: :ok | {:error, term()}
  def disable_request_interception(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    Browser.release_interception(page.browser, page, timeout)
  end

  @doc """
  Blocks requests of the given resource types on the page: each one fails with
  `net::ERR_BLOCKED_BY_CLIENT` before it reaches the network. A common scraping
  speed-up: less proxy traffic and faster loads.

      :ok = CDPEx.Page.block_resources(page, [:image, :font, :media])

  The list replaces the page's previous one; `[]` turns blocking off. To block from
  the first navigation, pass `block:` to `CDPEx.Browser.new_page/2` instead (also
  accepted by `CDPEx.with_page/3` and `CDPEx.Pool.with_page/3`).

  Types: `:image`, `:font`, `:media`, `:stylesheet`, `:script`, `:xhr`, `:fetch`,
  `:text_track`, `:manifest`, `:prefetch`, `:ping`, `:event_source`, `:other`.
  `:document` is not accepted (it would fail the page's own navigation; iframes share
  the type, so block those by URL with `enable_request_interception/2`), nor is
  `:websocket` (Chrome doesn't pause WebSocket handshakes, so it would do nothing). An
  invalid value returns `{:error, {:invalid_args, {:block, value}}}`.

  The library fails the requests itself, so no process has to handle them and the
  calling process may exit; blocking lasts until changed or until the page closes.
  It combines with `authenticate/4`, a credentialed `:proxy` and
  `enable_request_interception/2`. A blocked type never reaches the interception
  owner, even when its patterns match it. Without login on the page, only the
  blocked types are paused, so the other requests cost nothing extra.

  Cross-site iframes are covered too, nested ones included: Chrome runs each as its
  own target, which the library attaches, filters and resumes before it loads.

  Unblocking doesn't reload what was already blocked, and navigating the page to the
  same document again may reuse Chrome's in-memory result for it without a request.

  A `{:error, {:timeout, :block_resources}}` may still take effect later; call again
  to settle the list.

  Options:
    * `:timeout` — ms for the CDP calls (default 10_000)
  """
  @spec block_resources(t(), [atom()], keyword()) :: :ok | {:error, term()}
  def block_resources(%__MODULE__{frame: nil} = page, types, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with {:ok, cdp_types} <- Fetch.resource_types(types) do
      Browser.block(page.browser, page, cdp_types, timeout)
    end
  end

  @pattern_keys %{
    "urlPattern" => "urlPattern",
    "resourceType" => "resourceType",
    "requestStage" => "requestStage",
    urlPattern: "urlPattern",
    resourceType: "resourceType",
    requestStage: "requestStage"
  }

  # The Fetch owner matches the patterns itself (with login on, they aren't all sent to
  # Chrome), so check them here rather than leave it to Chrome's validation.
  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.reduce_while([], fn pattern, acc ->
      case normalize_pattern(pattern) do
        {:ok, p} -> {:cont, [p | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, {:invalid_args, {:patterns, patterns}}}
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  defp normalize_patterns(patterns), do: {:error, {:invalid_args, {:patterns, patterns}}}

  defp normalize_pattern(pattern) when is_map(pattern) do
    Enum.reduce_while(pattern, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case {Map.get(@pattern_keys, key), value} do
        {"requestStage", stage} when stage in ["Request", "Response"] ->
          {:cont, {:ok, Map.put(acc, "requestStage", stage)}}

        {"requestStage", _} ->
          {:halt, :error}

        {name, value} when is_binary(name) and is_binary(value) ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp normalize_pattern(_pattern), do: :error

  @doc """
  Lets a paused request proceed (`Fetch.continueRequest`), optionally rewriting it.

  `:url`, `:method`, and `:headers` are **verbatim overrides, not merges**. In
  particular `:headers` *replaces the entire request header set*, so passing it to
  set one header drops everything Chrome would otherwise send (`User-Agent`,
  `Accept`, `Cookie`, …). Omit `:headers` to leave the original request headers
  intact (the same gotcha as Puppeteer's `continueRequest({headers})`).

  Options (all optional): `:url`, `:method`, `:headers` (a name => value map or
  keyword list), `:post_data` (a binary or iodata, base64-encoded for you), `:timeout`.
  """
  @spec continue_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def continue_request(%__MODULE__{frame: nil} = page, request_id, opts \\ [])
      when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params =
      %{"requestId" => request_id}
      |> put_present("url", Keyword.get(opts, :url))
      |> put_present("method", Keyword.get(opts, :method))
      |> put_present("headers", header_entries(Keyword.get(opts, :headers)))
      |> put_present("postData", encode64(Keyword.get(opts, :post_data)))

    ok_call(page, "Fetch.continueRequest", params, timeout)
  end

  @doc """
  Answers a paused request with a synthetic response (`Fetch.fulfillRequest`) — the
  page never hits the network for it.

  Options: `:status` (response code, default 200), `:headers` (a name => value map or
  keyword list), `:body` (a binary or iodata, base64-encoded for you), `:timeout`.
  """
  @spec fulfill_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def fulfill_request(%__MODULE__{frame: nil} = page, request_id, opts \\ [])
      when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params =
      %{"requestId" => request_id, "responseCode" => Keyword.get(opts, :status, 200)}
      |> put_present("responseHeaders", header_entries(Keyword.get(opts, :headers)))
      |> put_present("body", encode64(Keyword.get(opts, :body)))

    ok_call(page, "Fetch.fulfillRequest", params, timeout)
  end

  @doc """
  Fails a paused request (`Fetch.failRequest`).

  `:reason` (default `:failed`) is one of `:failed`, `:aborted`, `:timed_out`,
  `:access_denied`, `:connection_closed`, `:connection_reset`, `:connection_refused`,
  `:name_not_resolved`, `:internet_disconnected`, `:address_unreachable`,
  `:blocked_by_client`, `:blocked_by_response`. An unknown value returns
  `{:error, {:invalid_error_reason, value}}`.
  """
  @spec fail_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def fail_request(%__MODULE__{frame: nil} = page, request_id, opts \\ [])
      when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case error_reason(Keyword.get(opts, :reason, :failed)) do
      {:ok, reason} ->
        ok_call(
          page,
          "Fetch.failRequest",
          %{"requestId" => request_id, "errorReason" => reason},
          timeout
        )

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sets extra HTTP headers sent with every subsequent request on this page.

  `headers` is a map of header name => value; set them before navigating for
  them to apply to that navigation. Lazily enables `Network`. Options: `:timeout`.
  """
  @spec set_extra_headers(t(), %{optional(String.t()) => String.t()}, keyword()) ::
          :ok | {:error, term()}
  def set_extra_headers(%__MODULE__{frame: nil} = page, headers, opts \\ []) when is_map(headers) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <-
           do_call(
             page,
             "Network.setExtraHTTPHeaders",
             %{"headers" => headers},
             timeout
           ) do
      :ok
    end
  end

  @doc """
  Overrides the page's User-Agent (`Emulation.setUserAgentOverride`).

  Options:
    * `:user_agent_metadata` — a CDP `Emulation.UserAgentMetadata` map (string keys,
      e.g. `%{"platform" => "macOS", "mobile" => false, "brands" => [...]}`). Sets the
      UA Client Hints surface (`navigator.userAgentData`, the `Sec-CH-UA*` headers) so
      it stays consistent with the UA string. Overriding only the string leaves Client
      Hints at Chrome's defaults — a visible `navigator.userAgent` ↔ Client-Hints
      mismatch. Passed through verbatim, so it must match the CDP shape: a partial or
      empty map is **not** dropped — it's sent as-is and Chrome rejects the whole
      `setUserAgentOverride` call. Omit the option entirely to leave Client Hints at
      Chrome's default.
    * `:accept_language` — value for the `Accept-Language` header and `navigator.language`
      (e.g. `"en-US"`).
    * `:timeout` (default 10_000).

  ## Example

      Page.set_user_agent(page, "Mozilla/5.0 (Macintosh…) Chrome/120.0.0.0 Safari/537.36",
        user_agent_metadata: %{
          "platform" => "macOS",
          "platformVersion" => "14.0.0",
          "architecture" => "arm",
          "model" => "",
          "mobile" => false,
          "brands" => [
            %{"brand" => "Chromium", "version" => "120"},
            %{"brand" => "Not=A?Brand", "version" => "24"}
          ]
        },
        accept_language: "en-US"
      )
  """
  @spec set_user_agent(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def set_user_agent(%__MODULE__{frame: nil} = page, user_agent, opts \\ [])
      when is_binary(user_agent) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params =
      %{"userAgent" => user_agent}
      |> put_present("userAgentMetadata", Keyword.get(opts, :user_agent_metadata))
      |> put_present("acceptLanguage", Keyword.get(opts, :accept_language))

    case do_call(page, "Emulation.setUserAgentOverride", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Overrides the viewport via `Emulation.setDeviceMetricsOverride`.

  `width`/`height` are CSS pixels. Options: `:device_scale_factor` (default 1),
  `:mobile` (default `false`), `:timeout`. Returns `:ok`.
  """
  @spec set_viewport(t(), pos_integer(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def set_viewport(%__MODULE__{frame: nil} = page, width, height, opts \\ [])
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params = %{
      "width" => width,
      "height" => height,
      "deviceScaleFactor" => Keyword.get(opts, :device_scale_factor, 1),
      "mobile" => Keyword.get(opts, :mobile, false)
    }

    case do_call(page, "Emulation.setDeviceMetricsOverride", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Renders the page to PDF (`Page.printToPDF`).

  Returns `{:ok, data}` where `data` is the PDF bytes — or, when `:path` is
  given, the written file path (also a binary). Options: `:path`, `:landscape`
  (default `false`), `:print_background` (default `true`), `:timeout` (default 30_000).
  """
  @spec pdf(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def pdf(%__MODULE__{frame: nil} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @screenshot_timeout)

    params = %{
      "landscape" => Keyword.get(opts, :landscape, false),
      "printBackground" => Keyword.get(opts, :print_background, true)
    }

    with {:ok, %{"data" => base64}} <-
           do_call(page, "Page.printToPDF", params, timeout),
         {:ok, bytes} <- decode_base64(base64, :invalid_pdf_data) do
      write_or_return(bytes, Keyword.get(opts, :path))
    end
  end

  defp maybe_full_page(params, true), do: Map.put(params, "captureBeyondViewport", true)
  defp maybe_full_page(params, false), do: params

  defp decode_base64(base64, error_tag) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {error_tag, String.slice(base64, 0, 500)}}
    end
  end

  defp write_or_return(bytes, nil), do: {:ok, bytes}

  defp write_or_return(bytes, path) do
    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  # For a wait whose :timeout spans the lazy enable: running out of budget there is
  # the wait's own {:error, :timeout}, not the enable call's.
  defp enable_network_within(page, deadline) do
    case ensure_network(page, remaining(deadline)) do
      {:error, {:timeout, "Network.enable"}} -> {:error, :timeout}
      other -> other
    end
  end

  # Lazily enable the Network domain (idempotent in CDP) so cookie/header ops
  # work without callers opting in at page creation — keeps Page stateless.
  defp ensure_network(page, timeout) do
    case do_call(page, "Network.enable", %{}, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # Subscribe the caller to a list of event methods, stopping at the first failure.
  # `timeout` lets a caller fold the registration into an overall deadline; a snapshot is
  # fine — if one subscribe exhausts it the rest are skipped. A budget-exhausted call
  # surfaces as :timeout (the conn is alive, the deadline elapsed) vs :noproc for a
  # genuinely dead conn.
  defp subscribe_each(conn, methods, timeout, session_id) do
    Enum.reduce_while(methods, :ok, fn method, :ok ->
      case Connection.subscribe(conn, method, timeout, session_id: session_id) do
        :ok -> {:cont, :ok}
        {:error, {:timeout, :subscribe}} -> {:halt, {:error, :timeout}}
        {:error, :noproc} -> {:halt, {:error, :noproc}}
        {:error, {:ws_closed, _}} = error -> {:halt, error}
      end
    end)
  end

  # Only the subscriptions made for this page's session (nil on a :dedicated page), so a
  # process watching several :session pages of one browser keeps the others.
  defp unsubscribe_each(conn, methods, session_id) do
    Enum.each(methods, &Connection.unsubscribe(conn, &1, session_id: session_id))
  end

  defp ok_call(page, method, params, timeout) do
    case do_call(page, method, params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp header_entries(nil), do: nil

  # Accept a map or a keyword list (both are natural for headers); Enum.map handles
  # either's {name, value} pairs. A genuinely-wrong shape still raises.
  defp header_entries(headers) when is_map(headers) or is_list(headers) do
    Enum.map(headers, fn {name, value} ->
      %{"name" => to_string(name), "value" => to_string(value)}
    end)
  end

  defp encode64(nil), do: nil
  # Accept a binary or iodata — IO.iodata_to_binary/1 flattens either (and a
  # genuinely-wrong type, e.g. an integer, still raises).
  defp encode64(data), do: Base.encode64(IO.iodata_to_binary(data))

  @error_reasons %{
    failed: "Failed",
    aborted: "Aborted",
    timed_out: "TimedOut",
    access_denied: "AccessDenied",
    connection_closed: "ConnectionClosed",
    connection_reset: "ConnectionReset",
    connection_refused: "ConnectionRefused",
    name_not_resolved: "NameNotResolved",
    internet_disconnected: "InternetDisconnected",
    address_unreachable: "AddressUnreachable",
    blocked_by_client: "BlockedByClient",
    blocked_by_response: "BlockedByResponse"
  }

  defp error_reason(reason) do
    case Map.fetch(@error_reasons, reason) do
      {:ok, cdp} -> {:ok, cdp}
      :error -> {:error, {:invalid_error_reason, reason}}
    end
  end

  @doc false
  @spec keymap(String.t()) :: {:ok, map()} | {:error, {:unknown_key, String.t()}}
  def keymap(key) do
    case Map.fetch(@keymap, key) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, {:unknown_key, key}}
    end
  end

  # Page ops thread the page's session id (`nil` for a dedicated page) so the same
  # code path serves both the one-socket-per-page and the multiplexed transports.
  # ── frames ────────────────────────────────────────────────────────────────────

  defp top(%__MODULE__{frame: nil} = page), do: page
  defp top(%__MODULE__{frame: %{parent: parent}}), do: top(parent)

  # Where a page's or frame's script runs: the page itself, or for a frame either its
  # parent's session (a child frame there, in the context of its main world) or its
  # own session on the browser connection (an out-of-process frame). Resolved on each
  # call, because a navigation can move a frame between processes, and a cross-site
  # <iframe> starts out in its parent's process on the initial about:blank.
  defp route(%__MODULE__{frame: nil} = page, _timeout), do: {:ok, page, nil}

  defp route(%__MODULE__{frame: frame} = page, timeout) do
    with {:ok, parent, _context_id} <- route(frame.parent, timeout) do
      case Connection.frame_context(parent.conn, parent.session_id, frame.id, timeout) do
        {:ok, context_id} -> {:ok, parent, context_id}
        :error -> own_session(top(page), frame, timeout)
        {:error, _} = error -> error
      end
    end
  end

  defp own_session(top, frame, timeout) do
    case Browser.attach_frame(top.browser, top, frame.id, timeout) do
      {:ok, conn, session_id} ->
        {:ok, %{top | conn: conn, session_id: session_id}, nil}

      {:error, :no_target} ->
        {:error, {:frame_unavailable, frame.label}}

      {:error, _} = error ->
        error
    end
  end

  defp put_context(params, _key, nil), do: params
  defp put_context(params, key, context_id), do: Map.put(params, key, context_id)

  # Mouse events go to the top page in its viewport's coordinates: a point in a frame
  # is shifted by its <iframe>'s content box in the parent, level by level, and each
  # level checks that the parent's element at the shifted point is that <iframe>, so
  # a click can't land on whatever covers the frame. The <iframe> is scrolled into
  # view in its parent first.
  defp to_top(%__MODULE__{frame: nil}, x, y, _label, _timeout), do: {:ok, x, y}

  defp to_top(%__MODULE__{frame: %{parent: parent, owner: owner}}, x, y, label, timeout) do
    shift = """
    function (x, y) {
      var el = this;
      if (el.scrollIntoViewIfNeeded) { el.scrollIntoViewIfNeeded(); }
      else { el.scrollIntoView({block: "center", inline: "center"}); }
      var r = el.getBoundingClientRect(), s = getComputedStyle(el);
      var px = r.left + el.clientLeft + parseFloat(s.paddingLeft) + x;
      var py = r.top + el.clientTop + parseFloat(s.paddingTop) + y;
      var root = el.getRootNode();
      var probe = typeof root.elementFromPoint === "function" ? root : document;
      return probe.elementFromPoint(px, py) === el ? {x: px, y: py} : null;
    }
    """

    case call_on_node(parent, owner, shift, [x, y], timeout) do
      {:ok, %{"x" => px, "y" => py}} -> to_top(parent, px, py, label, timeout)
      {:ok, nil} -> {:locate, {:obscured, label}}
      {:error, reason} -> {:locate, reason}
    end
  end

  # Calls `function` with `this` = the node `backend_node_id` in `page`'s context and
  # returns its value; the node's handle is released afterwards.
  defp call_on_node(page, backend_node_id, function, args, timeout) do
    group = "cdp_ex-node-#{System.unique_integer([:positive])}"

    with {:ok, route, context_id} <- route(page, timeout),
         resolve =
           put_context(
             %{"backendNodeId" => backend_node_id, "objectGroup" => group},
             "executionContextId",
             context_id
           ),
         {:ok, %{"object" => %{"objectId" => object_id}}} <-
           do_call(route, "DOM.resolveNode", resolve, timeout) do
      params = %{
        "objectId" => object_id,
        "functionDeclaration" => function,
        "arguments" => Enum.map(args, &%{"value" => &1}),
        "returnByValue" => true
      }

      result =
        case do_call(route, "Runtime.callFunctionOn", params, timeout) do
          {:ok, result} -> Protocol.evaluate_result(result)
          {:error, _} = error -> error
        end

      _ = do_call(route, "Runtime.releaseObjectGroup", %{"objectGroup" => group}, timeout)
      result
    end
  end

  defp do_call(%__MODULE__{conn: conn, session_id: session_id}, method, params, timeout) do
    Connection.call(conn, method, params, timeout, session_id: session_id)
  end
end
