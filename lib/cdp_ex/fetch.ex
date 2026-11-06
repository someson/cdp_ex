defmodule CDPEx.Fetch do
  @moduledoc """
  Per-page owner of the CDP `Fetch` domain, backing `CDPEx.Page.authenticate/4`,
  the credentialed `:proxy` launch option and `CDPEx.Page.enable_request_interception/2`.

  It has three independent modes, so a page can answer a proxy's login, intercept
  requests and block resource types at the same time:

    * **auth** — answers authentication challenges (`Fetch.authRequired` →
      `Fetch.continueWithAuth`) with the configured credentials;
    * **intercept** — forwards paused requests (`Fetch.requestPaused`) that match the
      interception owner's patterns to that owner, as the original event tuple;
    * **block** — fails Request-stage pauses of the blocked resource types with
      `Fetch.failRequest` (`BlockedByClient`). It needs no owner process, and it wins
      over interception: a blocked type never reaches the interception owner.

  Every other paused request is let through with `Fetch.continueRequest`. With auth
  on, `Fetch.enable` pauses **every** request (Chrome raises `Fetch.authRequired` only
  for intercepted ones), so each request round-trips through this process —
  measurable overhead on resource-heavy pages.

  The Browser starts one per page on the first auth or interception request, and
  sends it requests with `request/3`; each result comes back to the Browser as
  `{:fetch_reply, pid, tag, result}`. The owner stays alive, idle once every mode is
  off, until the page ends: it stops when the page's connection goes down, when a
  `:session` page's session detaches, or on `stop/1`.

  Cross-site iframes run as their own Chrome targets. With any mode on, the owner turns
  on `Target.setAutoAttach` (iframes only, paused on start) for the page's session:
  each iframe that attaches, nested ones included, gets the page's `Fetch.enable`
  params on its own session and is then resumed, on every path. Block and auth answer
  there; interception covers the page's own frames only, so an iframe's other pauses
  are continued. With every mode off, auto-attach is turned off again.

  The owner also carries the console of those iframes for `CDPEx.Page.observe_console/2`.
  While a process observes, auto-attach stays on even with every mode off: each iframe
  gets `Runtime.enable` on its own session before it is resumed, and its
  `Runtime.consoleAPICalled` / `Runtime.exceptionThrown` events reach every observer as
  the original event tuple, carrying the iframe's session id (passed on by the owner on
  a `:session` page; on a `:dedicated` page the observer's unfiltered subscription gets
  them from the connection). An observer
  that dies is dropped; with no observer and no mode left, auto-attach is turned off.

  This is an internal building block; use the `CDPEx.Page` functions.
  """

  use GenServer

  alias CDPEx.Connection
  alias CDPEx.ProcessLabel

  require Logger

  @call_timeout 10_000
  @max_tracked 1024
  @events ["Fetch.requestPaused", "Fetch.authRequired"]
  # A cross-site iframe is its own target: it attaches as a child session of the page
  # (or of its parent iframe), paused until resumed, so its Fetch domain is armed
  # before its first request.
  @target_events ["Target.attachedToTarget", "Target.detachedFromTarget"]
  @console_events ["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]
  @child_events @events ++ @target_events ++ @console_events
  @auto_attach %{
    "autoAttach" => true,
    "waitForDebuggerOnStart" => true,
    "flatten" => true,
    "filter" => [%{"type" => "iframe"}]
  }

  defstruct [
    :conn,
    :session_id,
    :browser,
    # nil | %{credentials, source, tag}; credentials is a zero-arity fun returning
    # {username, password}, so crash reports and :sys.get_status/1 never print them.
    auth: nil,
    # nil | %{owner, ref, patterns, matchers}
    intercept: nil,
    # nil | [CDP resource type string], deduplicated
    block: nil,
    # Console observers of the page's iframes: monitor ref => {pid, methods}.
    console: %{},
    subscribed: false,
    # Target.setAutoAttach is on for the page's session.
    auto_attach: false,
    # Child sessions of attached cross-site iframes (session id => true).
    children: %{},
    # {session_id, requestId} => answers given, for the bad-credentials guard.
    attempts: %{},
    # requestIds forwarded to the interception owner, released if it goes away
    forwarded: MapSet.new(),
    # The session detached or the page ended: its Fetch domain went with it, so there
    # is nothing to disable.
    detached: false
  ]

  @type t :: %__MODULE__{}

  @typedoc false
  @type request ::
          {:auth, %{credentials: (-> {String.t(), String.t()}), source: atom()}}
          | {:drop_auth, reference()}
          | {:intercept, pid(), [map()], timeout()}
          | {:release_intercept, timeout()}
          | {:block, [String.t()], timeout()}
          | {:observe_console, pid(), [String.t()], timeout()}
          | {:unobserve_console, pid()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  # Asynchronous: the result arrives at the Browser as {:fetch_reply, pid, tag, result}.
  @spec request(pid(), reference(), request()) :: :ok
  def request(pid, tag, request) do
    send(pid, {:fetch_request, tag, request})
    :ok
  end

  @doc false
  # The page ended: stop without touching its (gone) Fetch domain.
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.cast(pid, :page_gone)

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    ProcessLabel.set({:cdp_fetch, Keyword.get(opts, :target_id)})
    # Stop when the page connection goes down.
    Process.monitor(conn)

    {:ok,
     %__MODULE__{
       conn: conn,
       session_id: Keyword.get(opts, :session_id),
       browser: Keyword.fetch!(opts, :browser)
     }}
  end

  @impl true
  def handle_cast(:page_gone, state), do: {:stop, :normal, %{state | detached: true}}

  @impl true
  def handle_info({:fetch_request, tag, request}, state) do
    {result, state} = apply_request(request, tag, state)
    send(state.browser, {:fetch_reply, self(), tag, result})
    {:noreply, state}
  end

  def handle_info(
        {:cdp_event, conn, "Fetch.requestPaused", %{"requestId" => request_id} = params, sid},
        %__MODULE__{conn: conn} = state
      )
      when is_map_key(state.children, sid) do
    # An iframe's pause: block applies there too; interception covers the page's own
    # frames only, so everything else goes on.
    case decide(%{state | intercept: nil}, params) do
      :block ->
        _ = fail_blocked(state, sid, request_id)
        {:noreply, state}

      _continue ->
        _ = call_on(state, sid, "Fetch.continueRequest", %{"requestId" => request_id})
        {:noreply, state}
    end
  end

  def handle_info(
        {:cdp_event, conn, "Fetch.requestPaused", %{"requestId" => request_id} = params, sid} =
          event,
        %__MODULE__{conn: conn, session_id: sid} = state
      ) do
    case decide(state, params) do
      :block ->
        _ = fail_blocked(state, sid, request_id)
        {:noreply, state}

      :forward ->
        send(state.intercept.owner, event)
        {:noreply, %{state | forwarded: track(state.forwarded, request_id)}}

      :continue ->
        _ = call(state, "Fetch.continueRequest", %{"requestId" => request_id})
        {:noreply, state}
    end
  end

  def handle_info(
        {:cdp_event, conn, "Fetch.authRequired", %{"requestId" => request_id} = params, sid},
        %__MODULE__{conn: conn, auth: %{} = auth} = state
      )
      when sid == state.session_id or is_map_key(state.children, sid) do
    {response, attempts} =
      auth_decision(
        auth.source,
        state.attempts,
        {sid, request_id},
        params["authChallenge"] || %{},
        auth.credentials
      )

    _ =
      call_on(state, sid, "Fetch.continueWithAuth", %{
        "requestId" => request_id,
        "authChallengeResponse" => response
      })

    {:noreply, %{state | attempts: attempts}}
  end

  # An iframe's console on a :session page: every observer gets the event as it came,
  # with the iframe's session id. A :dedicated page's observers subscribed with no
  # session filter on the page's own connection, so they get the iframes' events from
  # it directly and nothing is passed on.
  def handle_info({:cdp_event, conn, method, _params, sid} = event, %__MODULE__{conn: conn} = state)
      when method in @console_events and is_map_key(state.children, sid) and
             is_binary(state.session_id) do
    for {_ref, {pid, methods}} <- state.console, method in methods, do: send(pid, event)
    {:noreply, state}
  end

  # A console observer died without unobserving. Keyed by the monitor ref: the same
  # process may also be the interception owner, with a monitor of its own.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.console, ref) do
    {:noreply, drop_observer(state, ref)}
  end

  # A cross-site iframe attached under the page or one of its iframes.
  def handle_info(
        {:cdp_event, conn, "Target.attachedToTarget", %{"sessionId" => child} = params, parent},
        %__MODULE__{conn: conn} = state
      )
      when is_binary(child) and (parent == state.session_id or is_map_key(state.children, parent)) do
    {:noreply, arm_child(state, child, params)}
  end

  def handle_info({:DOWN, _ref, :process, conn, _reason}, %__MODULE__{conn: conn} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %__MODULE__{intercept: %{ref: ref}} = state
      ) do
    # The interception owner died without disabling: leave the page usable.
    case drop_intercept(state, @call_timeout) do
      {:ok, state} ->
        {:noreply, state}

      {{:error, reason}, state} ->
        if not benign?(reason) do
          Logger.warning(
            "[CDPEx.Fetch] releasing interception after its owner died returned #{inspect(reason)}; the page may remain intercepted"
          )
        end

        {:noreply, state}
    end
  end

  # Our :session page's session ended. Chrome sends the detach on the parent session,
  # so it is matched on params, not on the event's session id.
  def handle_info(
        {:cdp_event, conn, "Target.detachedFromTarget", %{"sessionId" => sid}, _parent},
        %__MODULE__{conn: conn, session_id: sid} = state
      )
      when is_binary(sid) do
    {:stop, :normal, %{state | detached: true}}
  end

  # An iframe went away (navigated, removed, its parent gone): forget its session.
  def handle_info(
        {:cdp_event, conn, "Target.detachedFromTarget", %{"sessionId" => child}, _parent},
        %__MODULE__{conn: conn} = state
      )
      when is_map_key(state.children, child) do
    Enum.each(@child_events, &Connection.unsubscribe(conn, &1, session_id: child))
    {:noreply, %{state | children: Map.delete(state.children, child)}}
  end

  # Includes Fetch.authRequired while auth is off: it isn't ours to answer (a caller
  # that enabled handleAuthRequests itself answers it).
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: the connection may already be gone (Connection.call and
    # safe_unsubscribe both tolerate that), leaving nothing to disable.
    # Auto-attach goes off too, observers or not: nobody would resume a new iframe.
    _ =
      cond do
        state.detached -> :ok
        any_mode?(state) -> disable_all(%{state | console: %{}}, @call_timeout)
        state.auto_attach -> stop_auto_attach(state, @call_timeout)
        true -> :ok
      end

    _ = if not state.detached, do: resume_queued_attaches(state)
    _ = if state.subscribed, do: safe_unsubscribe(state)
    :ok
  end

  # An iframe whose attach is still in our mailbox is paused, and only its own session
  # can resume it: Chrome doesn't resume it when auto-attach goes off, the session
  # detaches, or another session attaches to it. Stopping before handling the attach
  # (a crash in an earlier message) would leave it, and the page's load, hanging.
  # Our subscriptions are filtered to our page's sessions, so every attach here is ours.
  defp resume_queued_attaches(%__MODULE__{conn: conn} = state) do
    receive do
      {:cdp_event, ^conn, "Target.attachedToTarget", %{"sessionId" => child} = params, _parent}
      when is_binary(child) ->
        _ =
          if params["waitingForDebugger"] != false,
            do: call_on(state, child, "Runtime.runIfWaitingForDebugger", %{})

        resume_queued_attaches(state)
    after
      0 -> :ok
    end
  end

  # ── requests ────────────────────────────────────────────────────────────────

  defp apply_request({:auth, _creds}, _tag, %__MODULE__{auth: %{}} = state),
    do: {{:error, :already_authenticated}, state}

  defp apply_request({:auth, creds}, tag, state) do
    next = %{state | auth: Map.put(creds, :tag, tag), attempts: %{}}
    rearm(state, next, @call_timeout)
  end

  defp apply_request({:drop_auth, tag}, _tag, %__MODULE__{auth: %{tag: tag}} = state),
    do: rearm(state, %{state | auth: nil, attempts: %{}}, @call_timeout)

  defp apply_request({:drop_auth, _other}, _tag, state), do: {:ok, state}

  defp apply_request({:intercept, _, _, _}, _tag, %__MODULE__{intercept: %{}} = state),
    do: {{:error, :already_intercepting}, state}

  defp apply_request({:intercept, owner, patterns, timeout}, _tag, state) do
    ref = Process.monitor(owner)

    intercept = %{
      owner: owner,
      ref: ref,
      patterns: patterns,
      matchers: compile_matchers(patterns)
    }

    case rearm(state, %{state | intercept: intercept, forwarded: MapSet.new()}, timeout) do
      {:ok, _} = ok ->
        ok

      {error, state} ->
        Process.demonitor(ref, [:flush])
        {error, state}
    end
  end

  defp apply_request({:block, types, timeout}, _tag, state) do
    block = if types == [], do: nil, else: types
    rearm(state, %{state | block: block}, timeout)
  end

  # Subscribe to the page's attaches, give the iframes already attached their console,
  # then make sure new ones attach. A failed auto-attach is logged, not returned: the
  # page's own console still works. A second call from the same process replaces its
  # methods.
  defp apply_request({:observe_console, pid, methods, timeout}, _tag, state) do
    case observer_ref(state, pid) do
      nil -> add_observer(state, pid, methods, timeout)
      ref -> {:ok, %{state | console: Map.put(state.console, ref, {pid, methods})}}
    end
  end

  defp apply_request({:unobserve_console, pid}, _tag, state) do
    case observer_ref(state, pid) do
      nil ->
        {:ok, state}

      ref ->
        Process.demonitor(ref, [:flush])
        {:ok, drop_observer(state, ref)}
    end
  end

  defp apply_request({:release_intercept, _timeout}, _tag, %__MODULE__{intercept: nil} = state),
    do: {:ok, state}

  defp apply_request({:release_intercept, timeout}, _tag, state) do
    Process.demonitor(state.intercept.ref, [:flush])
    drop_intercept(state, timeout)
  end

  # Interception ends (released or its owner died). With another mode still on (auth or
  # block), the pauses already forwarded would stay paused after the re-enable, so let
  # them through first; a continueRequest for one the owner already resolved fails
  # harmlessly. With every other mode off, Fetch.disable releases them.
  defp drop_intercept(state, timeout) do
    if state.auth || state.block do
      Enum.each(state.forwarded, &call(state, "Fetch.continueRequest", %{"requestId" => &1}))
    end

    {result, next} =
      rearm(state, %{state | intercept: nil, forwarded: MapSet.new()}, timeout)

    # The mode is gone whatever the CDP result: its owner is gone or released it.
    {result, %{next | intercept: nil, forwarded: MapSet.new()}}
  end

  # Apply `next`'s modes to the page's Fetch domain. On success the state becomes
  # `next`; on failure it stays `prev`, whose enable is still in effect.
  # A change that leaves the params as they are (block added while auth already pauses
  # everything, the same block set again) needs no CDP call.
  defp rearm(prev, next, timeout) do
    case {params_of(next), params_of(prev)} do
      {nil, _} -> disable(prev, next, timeout)
      {same, same} -> {:ok, next}
      {params, _} -> enable(prev, next, params, timeout)
    end
  end

  defp params_of(state),
    do: enable_params(state.auth, state.intercept && state.intercept.patterns, state.block)

  defp disable(%__MODULE__{auth: nil, intercept: nil, block: nil}, next, _timeout), do: {:ok, next}

  defp disable(_prev, next, timeout) do
    result = disable_all(next, timeout)
    next = if next.console == %{}, do: %{next | auto_attach: false}, else: next

    case result do
      {:ok, _} -> {:ok, next}
      {:error, reason} -> {{:error, reason}, next}
    end
  end

  # Every iframe first (turning auto-attach off may detach them), then the page: stop
  # pausing new iframes, unless a console observer still needs them, and release the
  # page's Fetch domain.
  defp disable_all(state, timeout) do
    Enum.each(Map.keys(state.children), &call_on(state, &1, "Fetch.disable", %{}, timeout))
    _ = if state.auto_attach and state.console == %{}, do: stop_auto_attach(state, timeout)
    call(state, "Fetch.disable", %{}, timeout)
  end

  defp stop_auto_attach(state, timeout),
    do: call(state, "Target.setAutoAttach", %{@auto_attach | "autoAttach" => false}, timeout)

  # The last observer gone with every mode off: new iframes need not attach any more.
  defp drop_observer(state, ref) do
    state = %{state | console: Map.delete(state.console, ref)}

    if state.console == %{} and state.auto_attach and params_of(state) == nil do
      _ = stop_auto_attach(state, @call_timeout)
      %{state | auto_attach: false}
    else
      state
    end
  end

  defp add_observer(state, pid, methods, timeout) do
    case ensure_subscribed(state, timeout) do
      {:ok, state} ->
        if state.console == %{},
          do: Enum.each(Map.keys(state.children), &enable_runtime(state, &1))

        state = %{state | console: Map.put(state.console, Process.monitor(pid), {pid, methods})}
        {:ok, ensure_auto_attach(state, timeout)}

      {:error, reason} ->
        arm_failed(reason, state)
    end
  end

  defp observer_ref(state, pid),
    do: Enum.find_value(state.console, fn {ref, {owner, _}} -> if owner == pid, do: ref end)

  # Auto-attach is needed while a mode filters requests or a process observes the console.
  defp attaching?(state), do: params_of(state) != nil or state.console != %{}

  defp enable(prev, next, params, timeout) do
    case ensure_subscribed(next, timeout) do
      {:ok, next} ->
        next = ensure_auto_attach(next, timeout)

        case call(next, "Fetch.enable", params, timeout) do
          {:ok, _} ->
            Enum.each(Map.keys(next.children), &enable_child(next, &1, params))
            {:ok, next}

          {:error, reason} ->
            arm_failed(reason, %{prev | subscribed: true, auto_attach: next.auto_attach})
        end

      {:error, reason} ->
        arm_failed(reason, prev)
    end
  end

  defp arm_failed(reason, state) do
    if not benign?(reason), do: Logger.warning("[CDPEx.Fetch] arming failed: #{inspect(reason)}")
    {{:error, reason}, state}
  end

  # Subscribe BEFORE the first enable so no paused request can slip through between
  # the enable and the first event delivery.
  defp ensure_subscribed(%__MODULE__{subscribed: true} = state, _timeout), do: {:ok, state}

  defp ensure_subscribed(state, timeout) do
    case subscribe_session(state, state.session_id, @events ++ @target_events, timeout) do
      :ok -> {:ok, %{state | subscribed: true}}
      {:error, _} = error -> error
    end
  end

  defp subscribe_session(state, sid, methods, timeout) do
    Enum.reduce_while(methods, :ok, fn method, :ok ->
      case Connection.subscribe(state.conn, method, timeout, session_id: sid) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Turn on iframe auto-attach for the page's session. A failure (an old Chrome, a
  # target that doesn't support it) leaves iframes unfiltered, not the page: logged.
  defp ensure_auto_attach(%__MODULE__{auto_attach: true} = state, _timeout), do: state

  defp ensure_auto_attach(state, timeout) do
    case call(state, "Target.setAutoAttach", @auto_attach, timeout) do
      {:ok, _} ->
        %{state | auto_attach: true}

      {:error, reason} ->
        if not benign?(reason),
          do: Logger.warning("[CDPEx.Fetch] iframe auto-attach failed: #{inspect(reason)}")

        state
    end
  end

  # A new iframe session: subscribe it, filter it with the page's current modes, turn
  # on its console for the observers, let it auto-attach its own iframes, then resume
  # it. The resume runs whatever failed before it, so an iframe is never left paused (it
  # then loads unfiltered: logged).
  defp arm_child(state, child, params) do
    state =
      case subscribe_session(state, child, @child_events, @call_timeout) do
        :ok -> %{state | children: Map.put(state.children, child, true)}
        {:error, reason} -> child_failed(state, child, reason)
      end

    _ =
      if is_map_key(state.children, child) and attaching?(state) do
        enable = params_of(state)
        _ = if enable, do: enable_child(state, child, enable)
        _ = if state.console != %{}, do: enable_runtime(state, child)
        _ = call_on(state, child, "Target.setAutoAttach", @auto_attach)
      end

    _ =
      if params["waitingForDebugger"] != false,
        do: call_on(state, child, "Runtime.runIfWaitingForDebugger", %{})

    state
  end

  defp enable_child(state, child, params) do
    case call_on(state, child, "Fetch.enable", params) do
      {:ok, _} -> :ok
      {:error, reason} -> child_failed(state, child, reason)
    end
  end

  defp enable_runtime(state, child) do
    case call_on(state, child, "Runtime.enable", %{}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if not benign?(reason) do
          Logger.warning(
            "[CDPEx.Fetch] Runtime.enable on iframe session #{child} failed: #{inspect(reason)}; its console is not observed"
          )
        end
    end
  end

  defp child_failed(state, child, reason) do
    if not benign?(reason) do
      Logger.warning(
        "[CDPEx.Fetch] arming iframe session #{child} failed: #{inspect(reason)}; its requests are not filtered"
      )
    end

    state
  end

  defp fail_blocked(state, sid, request_id) do
    call_on(state, sid, "Fetch.failRequest", %{
      "requestId" => request_id,
      "errorReason" => "BlockedByClient"
    })
  end

  # The page connection died, or a :session page's session detached, mid-arm (a
  # close/arm race) — no log.
  defp benign?(:noproc), do: true
  defp benign?({tag, _}) when tag in [:ws_closed, :session_closed], do: true
  defp benign?(_), do: false

  # ── pure helpers ────────────────────────────────────────────────────────────

  @block_types %{
    image: "Image",
    font: "Font",
    media: "Media",
    stylesheet: "Stylesheet",
    script: "Script",
    xhr: "XHR",
    fetch: "Fetch",
    text_track: "TextTrack",
    manifest: "Manifest",
    prefetch: "Prefetch",
    ping: "Ping",
    event_source: "EventSource",
    other: "Other"
  }

  @doc false
  # The CDP resource types for a `:block` value, deduplicated in order. `:document`
  # (it would fail the page's own navigation) and `:websocket` (the Fetch domain never
  # pauses a WebSocket handshake) are not in the table, so they are invalid.
  @spec resource_types(term()) :: {:ok, [String.t()]} | {:error, {:invalid_args, {:block, term()}}}
  def resource_types(value) when is_list(value) do
    if Enum.all?(value, &Map.has_key?(@block_types, &1)),
      do: {:ok, value |> Enum.map(&Map.fetch!(@block_types, &1)) |> Enum.uniq()},
      else: {:error, {:invalid_args, {:block, value}}}
  end

  def resource_types(value), do: {:error, {:invalid_args, {:block, value}}}

  defp any_mode?(state), do: state.auth != nil or state.intercept != nil or state.block != nil

  @doc false
  # The Fetch.enable params for a page's modes, or nil when every mode is off. With auth
  # on every request pauses anyway, so block changes nothing; with auth off, the blocked
  # types pause at the Request stage, ahead of the caller's patterns.
  @spec enable_params(map() | nil, [map()] | nil, [String.t()] | nil) :: map() | nil
  def enable_params(nil, patterns, block) do
    blocked = for type <- block || [], do: %{"resourceType" => type, "requestStage" => "Request"}

    case blocked ++ (patterns || []) do
      [] -> nil
      all -> %{"patterns" => all}
    end
  end

  def enable_params(_auth, nil, _block), do: %{"handleAuthRequests" => true}

  def enable_params(_auth, patterns, _block) do
    response = Enum.filter(patterns, &response_stage?/1)
    %{"patterns" => [%{"urlPattern" => "*"} | response], "handleAuthRequests" => true}
  end

  @doc false
  # What to do with a paused request: fail it (a blocked type at the Request stage),
  # forward it to the interception owner, or let it through. A Request-stage pause is
  # matched against the owner's patterns even when Chrome paused only those: with auth
  # or block on, more requests pause than the owner asked for, and a pause made under
  # the previous enable can arrive after a mode change (an image while the block set
  # shrank). The Response stage only has the owner's patterns.
  @spec decide(t(), map()) :: :block | :forward | :continue
  def decide(state, params) do
    cond do
      state.block != nil and not response_pause?(params) and
          params["resourceType"] in state.block ->
        :block

      state.intercept == nil ->
        :continue

      owners?(state, params) ->
        :forward

      true ->
        :continue
    end
  end

  defp owners?(%__MODULE__{intercept: %{matchers: matchers}}, params),
    do: response_pause?(params) or matches?(matchers, params)

  @doc false
  # Compile the owner's Request-stage patterns into {url_regex, resource_type | nil}.
  @spec compile_matchers([map()]) :: [{Regex.t(), String.t() | nil}]
  def compile_matchers(patterns) do
    for pattern <- patterns, not response_stage?(pattern) do
      {glob_regex(Map.get(pattern, "urlPattern", "*")), Map.get(pattern, "resourceType")}
    end
  end

  @doc false
  @spec matches?([{Regex.t(), String.t() | nil}], map()) :: boolean()
  def matches?(matchers, params) do
    url = get_in(params, ["request", "url"]) || ""
    type = params["resourceType"]

    Enum.any?(matchers, fn {regex, resource_type} ->
      (resource_type == nil or resource_type == type) and Regex.match?(regex, url)
    end)
  end

  defp response_stage?(pattern), do: Map.get(pattern, "requestStage") == "Response"

  defp response_pause?(params),
    do: Map.has_key?(params, "responseStatusCode") or Map.has_key?(params, "responseErrorReason")

  # CDP's urlPattern: `*` is zero or more characters, `?` exactly one, `\` escapes.
  defp glob_regex(glob) do
    Regex.compile!("\\A" <> glob_source(glob, []) <> "\\z", "su")
  end

  defp glob_source(<<"\\", c::utf8, rest::binary>>, acc),
    do: glob_source(rest, [Regex.escape(<<c::utf8>>) | acc])

  defp glob_source(<<"*", rest::binary>>, acc), do: glob_source(rest, [".*" | acc])
  defp glob_source(<<"?", rest::binary>>, acc), do: glob_source(rest, ["." | acc])

  defp glob_source(<<c::utf8, rest::binary>>, acc),
    do: glob_source(rest, [Regex.escape(<<c::utf8>>) | acc])

  defp glob_source(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  # Decide the authChallengeResponse and the next attempts map for a challenge.
  # Pure, so the source filter + bad-credentials loop guard are unit-testable
  # without Chrome.
  # `request_key` keys the attempts map: {session_id, requestId}, since request ids
  # are per target and an iframe's session has its own.
  @spec auth_decision(atom(), map(), term(), map(), (-> {String.t(), String.t()})) ::
          {map(), map()}
  def auth_decision(source_filter, attempts, request_id, challenge, credentials) do
    cond do
      not source_match?(source_filter, challenge["source"]) ->
        {%{"response" => "Default"}, attempts}

      Map.get(attempts, request_id, 0) >= 1 ->
        # Already answered once; a repeat means the credentials were rejected —
        # cancel rather than loop forever.
        {%{"response" => "CancelAuth"}, Map.delete(attempts, request_id)}

      true ->
        {username, password} = credentials.()

        response = %{
          "response" => "ProvideCredentials",
          "username" => username,
          "password" => password
        }

        {response, track_attempt(attempts, request_id)}
    end
  end

  # Only the rejection path (`CancelAuth`) ever deletes an entry; a
  # successfully-answered challenge emits no same-id follow-up to prune on, so cap
  # the map to bound growth on a long-lived page that keeps meeting fresh
  # challenges. In practice (proxy creds are cached after the first success) the
  # live size is 0–1, so the cap is a safety valve; dropping entries at the cap at
  # most re-offers credentials once for a challenge still in flight.
  defp track_attempt(attempts, request_id) when map_size(attempts) >= @max_tracked,
    do: %{request_id => 1}

  defp track_attempt(attempts, request_id), do: Map.put(attempts, request_id, 1)

  # Forwarded ids are never pruned on resolution (the owner resolves them directly on
  # the connection), so cap the set the same way. Dropping ids at the cap can only
  # miss releasing a pause that was forwarded more than @max_tracked pauses ago.
  defp track(forwarded, request_id) do
    if MapSet.size(forwarded) >= @max_tracked,
      do: MapSet.new([request_id]),
      else: MapSet.put(forwarded, request_id)
  end

  defp source_match?(:any, _source), do: true
  defp source_match?(:proxy, "Proxy"), do: true
  defp source_match?(:server, "Server"), do: true
  defp source_match?(_filter, _source), do: false

  defp call(state, method, params, timeout \\ @call_timeout),
    do: call_on(state, state.session_id, method, params, timeout)

  defp call_on(state, sid, method, params, timeout \\ @call_timeout) do
    Connection.call(state.conn, method, params, timeout, session_id: sid)
  end

  defp safe_unsubscribe(state) do
    for method <- @child_events do
      Connection.unsubscribe(state.conn, method)
    end
  end
end
