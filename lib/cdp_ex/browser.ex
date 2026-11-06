defmodule CDPEx.Browser do
  @moduledoc """
  A GenServer owning a headless Chrome OS process and its CDP connections.

  `CDPEx.Browser` launches Chrome (via `CDPEx.Chrome`), opens a browser-level
  `CDPEx.Connection`, and creates pages on demand. It is the lifecycle owner:

    * It **traps exits** and links every connection, so a page connection crash
      is isolated (the page is dropped; the browser and other pages survive),
      while a browser-connection or Chrome death stops the browser cleanly.
    * For a **launched** browser, `terminate/2` always runs `CDPEx.Chrome.stop/1`
      — the no-orphan guarantee. Because that relies on `terminate/2`, supervise a
      launched browser with a `:shutdown` timeout, **not** `:brutal_kill`.

  A browser started via `CDPEx.connect/2` (connect-mode, `chrome: nil`) is the
  exception: it never launched Chrome, so `terminate/2` only closes the pages it
  opened and never reaps the remote process — `:brutal_kill` is harmless there.
  That target cleanup is **best-effort**: each `Target.closeTarget` is bounded by
  the call timeout, and against a slow-but-alive remote with several open pages the
  supervised shutdown budget can elapse before every tab is closed, leaving some
  open on the remote Chrome (it never affects the local process, which holds no
  Chrome to reap).

  Most callers use the `CDPEx` facade rather than this module directly.
  """

  use GenServer

  alias CDPEx.Chrome
  alias CDPEx.Connection
  alias CDPEx.Exits
  alias CDPEx.Fetch
  alias CDPEx.Page
  alias CDPEx.ProcessLabel
  alias CDPEx.Protocol
  alias CDPEx.Proxy
  alias CDPEx.Telemetry

  require Logger

  @create_timeout 10_000
  @bootstrap_timeout 10_000
  # Ceiling for the synchronous Fetch arm (proxy auth and/or block) during new_page, shared
  # by every request it sends (see reply_armed_page).
  @arm_timeout 15_000

  defstruct [
    :chrome,
    :browser_conn,
    :host,
    :port,
    :opts,
    :parent,
    :proxy_auth,
    # connect-mode (attached to a Chrome we didn't launch): drives the :session
    # default + the :dedicated rejection in new_page. Distinct from `chrome: nil`,
    # which a launched browser never is in production but a unit fixture can be.
    connected: false,
    # A `pipe: true` launch: CDP rides Chrome's Port, so there is no endpoint for a
    # :dedicated page's own socket. Like connect-mode, it defaults to :session.
    pipe: false,
    pages: %{},
    sessions: %{},
    # target_id => browserContextId for pages opened with `isolated: true`; the
    # context is disposed (closing its target) when the page ends.
    contexts: %{},
    # target_id => CDPEx.Fetch pid, the page's Fetch domain owner (auth + interception)
    fetchers: %{},
    # request tag => {from, caller_monitor_ref | nil, fetch_pid}: a caller parked until
    # its page's Fetch owner reports the result of its request
    pending: %{}
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a browser. See `CDPEx.Chrome` for launch options.

  Pass `:owner` (a pid) to set the process whose death triggers the browser's cleanup,
  overriding the default (the calling process). `CDPEx.Pool` uses this when adopting a
  browser it launched in a short-lived task.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, launch_opts} = Keyword.split(opts, [:name])
    validate_launch_opts!(launch_opts)
    GenServer.start_link(__MODULE__, launch_opts, gen_opts)
  end

  # init/1 launches Chrome unless :connect is truthy; check the launch options in the
  # caller first, since a raise inside init/1 exits down the link instead.
  @doc false
  @spec validate_launch_opts!(keyword()) :: :ok
  def validate_launch_opts!(opts) when is_list(opts) do
    if Keyword.get(opts, :connect), do: :ok, else: Chrome.validate_opts!(opts)
  end

  def validate_launch_opts!(opts) do
    raise ArgumentError, "invalid launch options #{inspect(opts)} (expected a keyword list)"
  end

  @doc false
  def child_spec(opts) do
    # terminate/2 reaps Chrome (kill + busy-poll + temp-dir cleanup, up to ~3.5s);
    # give it headroom over the GenServer default (5s) so a supervisor never
    # :brutal_kills mid-teardown and orphans Chrome.
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
  end

  @doc """
  Opens a new page (tab) and returns a `CDPEx.Page` handle.

  Options:
    * `:transport` — `:dedicated` (one WebSocket per page, strong crash isolation)
      or `:session` (multiplexed over the browser socket via a flattened CDP
      session — fewer sockets, but all session pages share the browser
      connection's fate: if it drops, they all go). A **launched** browser
      defaults to `:dedicated`; a **connected** browser (`CDPEx.connect/2`) or one
      launched with `pipe: true` defaults to `:session` and rejects `:dedicated` with
      `{:error, {:unsupported_transport, :dedicated}}`. Any other value returns
      `{:error, {:invalid_transport, value}}`.
    * `:dialogs` — how the page's JavaScript dialogs are answered: `:accept`
      (default), `:dismiss`, `{:accept, prompt_text}` or `:manual`; see
      `CDPEx.Page.set_dialogs/3`. An invalid value raises `ArgumentError`.
    * `:prevent_alerts` — deprecated: `false` stands for `dialogs: :manual` when
      `:dialogs` isn't given; `true` (the default) changes nothing.
    * `:isolated` — `true` opens the page in a new browser context (its own cookies,
      storage and cache), disposed when the page closes. Default `false`. A value that
      isn't a boolean raises `ArgumentError`.
    * `:block` — resource types to fail before they reach the network, e.g.
      `[:image, :font, :media]`; armed before the page is returned, so the first
      navigation is already filtered. See `CDPEx.Page.block_resources/3` for the types
      and how blocking combines with login and interception. An invalid value returns
      `{:error, {:invalid_args, {:block, value}}}` and opens no page.

  A `:session` page whose target goes away while it is being set up returns
  `{:error, {:session_closed, session_id}}` (`:transient`; open a new page).

  A browser that is gone, or stops before replying, returns `{:error, :noproc}`. One
  that can't serve the request within 95s returns `{:error, {:timeout, :new_page}}`;
  a page it still opens after that is not handed to anyone and stays open until the
  browser stops, so retrying on the same browser can pile these up — prefer a fresh
  browser (or stop this one) after a timeout.
  """
  @spec new_page(GenServer.server(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  # The call timeout covers the worst-case internal budget — Target.createBrowserContext
  # for an isolated page and Target.createTarget (@create_timeout each), the page
  # socket's WebSocket upgrade (15s, Connection's default) or Target.attachToTarget
  # (@create_timeout), bootstrap (up to 4 × @bootstrap_timeout) and the Fetch arm for
  # proxy auth and :block (@arm_timeout, shared): 90s on the slowest (dedicated, isolated, proxied) path, plus 5s of
  # slack — so a stalled stage can't make the caller give up while the Browser is
  # still working, which would orphan an armed page and its context. Normal new_page returns in well under
  # a second; this is only the pathological ceiling.
  def new_page(browser, opts \\ []) do
    # Validated here, in the caller: a bad option must not crash the Browser.
    case Keyword.get(opts, :isolated, false) do
      isolated when is_boolean(isolated) -> :ok
      other -> raise ArgumentError, ":isolated must be a boolean, got: #{inspect(other)}"
    end

    opts = Keyword.put(opts, :dialogs, dialog_policy!(opts))

    with {:ok, types} <- Fetch.resource_types(Keyword.get(opts, :block, [])) do
      call(browser, {:new_page, Keyword.put(opts, :block, types)}, 95_000, :new_page)
    end
  end

  defp dialog_policy!(opts) do
    case Keyword.fetch(opts, :dialogs) do
      {:ok, policy} -> Connection.dialog_policy!(policy)
      :error -> if Keyword.get(opts, :prevent_alerts, true) == false, do: :manual, else: :accept
    end
  end

  @doc """
  Closes a page opened with `new_page/2`.

  Returns `{:error, :unknown_page}` if the page does not belong to this browser
  (a handle from a different browser, or one that was already closed),
  `{:error, :noproc}` if the browser is gone (its pages went with it), and
  `{:error, {:timeout, :close_page}}` if it can't serve the request within 15s.
  """
  @spec close_page(GenServer.server(), Page.t()) ::
          :ok | {:error, :unknown_page | :noproc | {:timeout, :close_page}}
  def close_page(browser, %Page{} = page),
    do: call(browser, {:close_page, page}, 15_000, :close_page)

  # Internal hop for `CDPEx.Page.authenticate/4`, which owns the input contract
  # (credential guards + `:source` validation). Not part of the public API.
  @doc false
  @spec authenticate(GenServer.server(), Page.t(), keyword()) :: :ok | {:error, term()}
  def authenticate(browser, %Page{} = page, opts) do
    # The call runs in a throwaway process because the Browser monitors whoever made
    # it: when that process goes down while the handler is still arming, the Browser
    # tears the handler down (#40). A timeout caught in the caller would leave it alive
    # and the page stuck on :already_authenticated. The relay is linked to the caller so
    # the caller's death takes it down too, which is the :DOWN the Browser acts on; it
    # unlinks before replying so a caller that traps exits gets no stray {:EXIT}.
    caller = self()
    tag = make_ref()

    {pid, mon} =
      Process.spawn(
        fn ->
          ProcessLabel.set({:cdp_authenticate, page.target_id})
          reply = call(browser, {:authenticate, page, opts}, 15_000, :authenticate)
          Process.unlink(caller)
          send(caller, {tag, reply})
        end,
        [:link, :monitor]
      )

    receive do
      {^tag, reply} ->
        Process.demonitor(mon, [:flush])
        reply

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        Process.unlink(pid)

        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :noproc}
    end
  end

  # Internal hops for `CDPEx.Page.enable/disable_request_interception/2`, which own the
  # public contract. The page's `CDPEx.Fetch` owner does the work: it monitors the
  # calling process as the interception owner and forwards it the pauses that match
  # `patterns`. `timeout` bounds the CDP calls; the Browser request gets 5s on top.
  @doc false
  @spec intercept(GenServer.server(), Page.t(), [map()], timeout()) :: :ok | {:error, term()}
  def intercept(browser, %Page{} = page, patterns, timeout) do
    call(
      browser,
      {:intercept, page, patterns, timeout},
      timeout + 5_000,
      :enable_request_interception
    )
  end

  # Internal hop for `CDPEx.Page.block_resources/3`, which validates and converts the
  # types. Block mode has no owner process, so the caller isn't monitored.
  @doc false
  @spec block(GenServer.server(), Page.t(), [String.t()], timeout()) :: :ok | {:error, term()}
  def block(browser, %Page{} = page, types, timeout),
    do: call(browser, {:block, page, types, timeout}, timeout + 5_000, :block_resources)

  @doc false
  @spec release_interception(GenServer.server(), Page.t(), timeout()) :: :ok | {:error, term()}
  def release_interception(browser, %Page{} = page, timeout) do
    call(
      browser,
      {:release_interception, page, timeout},
      timeout + 5_000,
      :disable_request_interception
    )
  end

  @doc """
  Stops the browser, closing all pages.

  A launched browser also kills its Chrome; a connected one (`CDPEx.connect/2`)
  closes only the pages it opened and leaves the remote Chrome running.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(browser) do
    GenServer.stop(browser, :normal)
  catch
    # Already stopped, or stopped on its own (Chrome died) while this one was waiting.
    :exit, {reason, {GenServer, :stop, _}} when reason != :calling_self ->
      Exits.warn_unclean_stop("CDPEx.Browser", reason)
  end

  # A Browser that is gone, or stops before replying, took its pages with it.
  defp call(browser, request, timeout, op) do
    GenServer.call(browser, request, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, {:timeout, op}}
    :exit, {reason, {GenServer, :call, _}} when reason != :calling_self -> {:error, :noproc}
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(launch_opts) do
    Process.flag(:trap_exit, true)

    # Provisional, replaced in connect_browser/6: a boot wedged for the whole
    # :launch_timeout must not present as an unlabelled pid.
    ProcessLabel.set({:cdp_browser, :starting})

    # An explicit `:owner` overrides the :$ancestors-derived parent. CDPEx.Pool passes it
    # when adopting a browser launched in a throwaway task, so the owner-death self-reap
    # (the {:EXIT, parent, _} clause) still targets the real owner (the pool) rather than
    # the already-dead task — otherwise a hard-killed pool would orphan the browser.
    {owner, launch_opts} = Keyword.pop(launch_opts, :owner)
    {connect_ws, launch_opts} = Keyword.pop(launch_opts, :connect)
    {conn_opts, launch_opts} = Keyword.pop(launch_opts, :conn_opts, [])

    cond do
      connect_ws && Keyword.has_key?(launch_opts, :proxy) ->
        # :proxy is a Chrome launch flag (--proxy-server); connect-mode launches no
        # Chrome, so it could never take effect. Reject rather than silently ignore it.
        stop_init({:unsupported_with_connect, :proxy})

      connect_ws ->
        # Connect-mode: attach to an already-running Chrome. No Chrome.launch, and
        # chrome: nil so terminate/2 never reaps a process we didn't start.
        connect_browser(nil, connect_ws, launch_opts, owner || parent_pid(), nil, conn_opts)

      true ->
        {proxy, launch_opts} = Keyword.pop(launch_opts, :proxy)

        with {:ok, proxy_auth, launch_opts} <- apply_proxy(proxy, launch_opts),
             {:ok, chrome} <- Chrome.launch(launch_opts) do
          connect_browser(
            chrome,
            endpoint(chrome),
            launch_opts,
            owner || parent_pid(),
            proxy_auth,
            []
          )
        else
          {:error, reason} -> stop_init(reason)
        end
    end
  end

  # A failed init exits the process with `reason`, and through the link that exit
  # would kill a caller not trapping exits before start_link could return
  # {:error, reason}. Drop the link to the starter first; a supervisor or
  # CDPEx.Pool's launch task gets the same {:error, reason} as before.
  defp stop_init(reason) do
    case parent_pid() do
      pid when is_pid(pid) -> Process.unlink(pid)
      _ -> true
    end

    {:stop, reason}
  end

  # Credentials are kept as a closure: a fun's captured values are never printed, so
  # they stay out of crash reports, `:sys.get_status/1` and `inspect` of the state.
  defp credentials_fun(nil), do: nil
  defp credentials_fun(%{username: user, password: pass}), do: fn -> {user, pass} end

  defp endpoint(%{pipe: true, port: port}), do: {:pipe, port}
  defp endpoint(%{debug_url: debug_url}), do: debug_url

  # Translate the `:proxy` launch option into a `--proxy-server` flag (appended to
  # `:extra_args`) plus the credentials to arm each page with. A bad proxy value stops
  # init with `{:invalid_proxy, _}`, surfaced from `launch/1` as `{:error, _}`.
  defp apply_proxy(nil, launch_opts), do: {:ok, nil, launch_opts}

  defp apply_proxy(proxy, launch_opts) do
    # The flag is appended to :extra_args, which a full :args override discards — and
    # then arming auth for a proxy Chrome never received would be worse than a no-op
    # (every page paused through Fetch, interception blocked, no actual proxy). Reject
    # the ambiguous combination: use :extra_args, or put --proxy-server in :args yourself.
    if Keyword.has_key?(launch_opts, :args) do
      {:error, {:invalid_proxy, :args_override}}
    else
      case Proxy.parse(proxy) do
        {:ok, parsed} ->
          arg = Proxy.to_arg(parsed)
          launch_opts = Keyword.update(launch_opts, :extra_args, [arg], &(&1 ++ [arg]))
          {:ok, credentials_fun(Proxy.credentials(parsed)), launch_opts}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Connect the browser WebSocket (the launched Chrome's debug URL, or a remote
  # endpoint for connect-mode where `chrome` is nil). If the connect fails, init/1
  # returns {:stop, _} *before* the GenServer loop starts, so terminate/2 never
  # runs — reap Chrome here (when we own it) or leak the OS process and temp profile.
  defp connect_browser(chrome, endpoint, launch_opts, parent, proxy_auth, conn_opts) do
    {host, port} = endpoint_host(endpoint)

    # The OS pid is the one identifier that ties this GenServer to a row in `ps`.
    ProcessLabel.set({:cdp_browser, browser_label_id(chrome)})

    # Prune session entries when their target ends (tab closed/crashed, or our own
    # close_page) so long-lived browsers don't accumulate stale sessions — parity with
    # the dedicated path, which self-prunes on a page-conn EXIT. If the browser socket
    # dropped in the window after start_link, subscribe/4 fails — and since the
    # GenServer loop hasn't started, terminate/2 never runs, so reap Chrome (and the
    # conn) here or leak the OS process and temp profile.
    with {:ok, conn} <- start_browser_conn(endpoint, conn_opts),
         :ok <- subscribe_detached(conn) do
      {:ok,
       %__MODULE__{
         chrome: chrome,
         connected: is_nil(chrome),
         pipe: match?({:pipe, _}, endpoint),
         browser_conn: conn,
         host: host,
         port: port,
         opts: launch_opts,
         parent: parent,
         proxy_auth: proxy_auth
       }}
    else
      {:error, reason} ->
        if chrome, do: Chrome.stop(chrome)
        stop_init(reason)
    end
  end

  # A pipe browser has no host or port: its pages can't open their own socket.
  defp endpoint_host({:pipe, _port}), do: {nil, nil}

  defp endpoint_host(ws_url) do
    {_scheme, host, port, _path} = Protocol.parse_ws_url(ws_url)
    {host, port}
  end

  # The pipe connection must own Chrome's Port to receive its output. Nothing has
  # been sent on the Port since Chrome.launch/1's probe, so nothing lands in this
  # process's mailbox meanwhile. Port.connect/2 raises if Chrome already exited; the
  # exit status it delivered to us first says why.
  defp start_browser_conn({:pipe, port} = endpoint, conn_opts) do
    with {:ok, conn} <- Connection.start_link(endpoint, conn_opts) do
      try do
        Port.connect(port, conn)
        {:ok, conn}
      rescue
        ArgumentError ->
          safe_close(conn)

          receive do
            {^port, {:exit_status, status}} -> {:error, {:chrome_exited, status, ""}}
          after
            0 -> {:error, {:ws_closed, :closed}}
          end
      end
    end
  end

  defp start_browser_conn(ws_url, conn_opts), do: Connection.start_link(ws_url, conn_opts)

  defp subscribe_detached(conn) do
    case Connection.subscribe(conn, "Target.detachedFromTarget") do
      :ok ->
        :ok

      {:error, _} = error ->
        safe_close(conn)
        error
    end
  end

  defp browser_label_id(nil), do: :connected
  defp browser_label_id(%{os_pid: os_pid}) when is_integer(os_pid), do: os_pid
  defp browser_label_id(_chrome), do: :launched

  # The process that called start_link — our linked "owner" (a supervisor, or the
  # caller of CDPEx.launch). We trap exits, so when it dies we must shut down and
  # reap Chrome rather than mistaking its exit for a page connection's.
  defp parent_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      [name | _] when is_atom(name) -> Process.whereis(name)
      _ -> nil
    end
  end

  @impl true
  def handle_call({:new_page, opts}, _from, state) do
    # A connected browser defaults to :session and can't do :dedicated yet —
    # a per-page socket would have to target the remote host.
    session_only? = state.connected or state.pipe
    default = if session_only?, do: :session, else: :dedicated

    case Keyword.get(opts, :transport, default) do
      :dedicated when session_only? ->
        {:reply, {:error, {:unsupported_transport, :dedicated}}, state}

      :dedicated ->
        reply_dedicated_page(state, opts)

      :session ->
        reply_session_page(state, opts)

      other ->
        {:reply, {:error, {:invalid_transport, other}}, state}
    end
  end

  def handle_call({:close_page, %Page{target_id: tid, session_id: sid}}, _from, state)
      when not is_nil(sid) do
    case Map.get(state.sessions, tid) do
      ^sid ->
        # The page rides the shared browser connection; detach the session and
        # close the tab, but NEVER close that connection (other sessions use it).
        isolated = Map.has_key?(state.contexts, tid)
        detach_session(state.browser_conn, sid)
        state = end_target(state, tid)
        Telemetry.page(:stop, %{target_id: tid, transport: :session, isolated: isolated})
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, tid)}}

      _ ->
        {:reply, {:error, :unknown_page}, state}
    end
  end

  def handle_call({:close_page, %Page{target_id: tid, conn: conn}}, _from, state) do
    case Map.get(state.pages, tid) do
      ^conn ->
        # Close the target on the browser connection first (a page connection can't
        # cleanly close its own target), then stop the page connection — best-effort,
        # since either may already be gone.
        isolated = Map.has_key?(state.contexts, tid)
        state = end_target(state, tid)
        safe_close(conn)
        Telemetry.page(:stop, %{target_id: tid, transport: :dedicated, isolated: isolated})
        {:reply, :ok, %{state | pages: Map.delete(state.pages, tid)}}

      _ ->
        # Not one of this browser's pages (a handle from another browser, or one
        # already closed). Don't close the handle's connection or send a stray
        # closeTarget — doing so could stop a live page owned by another browser.
        {:reply, {:error, :unknown_page}, state}
    end
  end

  def handle_call(
        {:authenticate, %Page{conn: conn, target_id: tid, session_id: sid} = page, opts},
        {caller, _} = from,
        state
      ) do
    if own_page?(state, tid, conn, sid) do
      # The page's Fetch owner arms asynchronously and reports back with
      # {:fetch_reply, pid, tag, result}; the caller stays parked in `pending` until
      # then, so authenticate/4 returns once auth is armed without blocking this
      # GenServer for the whole enable. A second auth on the page is rejected by the
      # owner with :already_authenticated.
      #
      # We also MONITOR the caller: if its 15s authenticate/4 call times out (a slow
      # arm under scheduler starvation), the caller exits and the page would be left
      # armed with no waiting caller — a retry would hit :already_authenticated with
      # no way to recover but closing the page. On the caller's :DOWN we ask the owner
      # to drop that auth, so the page becomes re-authenticatable (#40).
      creds = %{
        credentials: Keyword.fetch!(opts, :credentials),
        source: Keyword.get(opts, :source, :any)
      }

      caller_ref = Process.monitor(caller)

      case fetch_request(state, page, from, caller_ref, {:auth, creds}) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason} ->
          Process.demonitor(caller_ref, [:flush])
          {:reply, {:error, reason}, state}
      end
    else
      # Not one of this browser's live pages (a handle from another browser, or an
      # already-closed one) — mirror close_page/2 instead of arming a handler on a
      # foreign connection and linking it to us.
      {:reply, {:error, :unknown_page}, state}
    end
  end

  def handle_call(
        {:intercept, %Page{conn: conn, target_id: tid, session_id: sid} = page, patterns, timeout},
        {caller, _} = from,
        state
      ) do
    if own_page?(state, tid, conn, sid) do
      # The Fetch owner monitors the caller as the interception owner and releases the
      # page if it dies without disabling, so a crashed or forgetful caller can't leave
      # it bricked with no resolver.
      case fetch_request(state, page, from, nil, {:intercept, caller, patterns, timeout}) do
        {:ok, state} -> {:noreply, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :unknown_page}, state}
    end
  end

  def handle_call(
        {:block, %Page{conn: conn, target_id: tid, session_id: sid} = page, types, timeout},
        from,
        state
      ) do
    cond do
      not own_page?(state, tid, conn, sid) ->
        {:reply, {:error, :unknown_page}, state}

      types == [] and not Map.has_key?(state.fetchers, tid) ->
        # Nothing is blocked and nothing owns the page's Fetch domain: nothing to undo.
        {:reply, :ok, state}

      true ->
        case fetch_request(state, page, from, nil, {:block, types, timeout}) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:release_interception, %Page{target_id: tid}, timeout}, from, state) do
    case Map.get(state.fetchers, tid) do
      nil ->
        {:reply, :ok, state}

      pid ->
        tag = make_ref()
        Fetch.request(pid, tag, {:release_intercept, timeout})
        {:noreply, %{state | pending: Map.put(state.pending, tag, {from, nil, pid})}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{chrome: %{port: port}} = state) do
    Logger.warning("[CDPEx.Browser] Chrome exited with status #{status}")
    Telemetry.error(status, :chrome_exited)
    {:stop, {:chrome_exited, status}, state}
  end

  # A pipe browser's connection owns Chrome's Port, so Chrome's exit status reaches
  # the connection, which stops with it: report it as the Port clause above does.
  def handle_info(
        {:EXIT, pid, {:shutdown, {:ws_closed, {:chrome_exited, status}}}},
        %{browser_conn: pid, pipe: true} = state
      ) do
    Logger.warning("[CDPEx.Browser] Chrome exited with status #{status}")
    Telemetry.error(status, :chrome_exited)
    {:stop, {:chrome_exited, status}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{browser_conn: pid} = state) do
    Telemetry.error(reason, :browser_connection_down)
    {:stop, browser_down_reason(reason), state}
  end

  def handle_info({:EXIT, pid, reason}, %{parent: pid} = state) do
    # Our owner (supervisor or the process that called CDPEx.launch) died. Shut
    # down with the same reason so `terminate/2` reaps Chrome — otherwise a
    # supervisor `:shutdown` would leave an orphaned browser and OS process.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    # A page connection or a page's Fetch owner exited (closed or crashed). Callers
    # still parked on that owner are failed now rather than left to their call
    # timeout. Then drop the pid from both maps: a stale page handle's next op returns
    # {:error, :noproc}, and a new auth or interception request starts a fresh owner.
    state = fail_pending(state, pid, reason)

    # A page connection that went away on its own (tab crashed or closed from outside)
    # takes its isolated context with it.
    state =
      case Enum.find(state.pages, fn {_tid, conn} -> conn == pid end) do
        {tid, _conn} -> page_gone(state, tid)
        nil -> state
      end

    {:noreply,
     %{state | pages: drop_conn(state.pages, pid), fetchers: drop_value(state.fetchers, pid)}}
  end

  def handle_info(
        {:cdp_event, conn, "Target.detachedFromTarget", params, _session_id},
        %{browser_conn: conn} = state
      ) do
    # A flattened session ended. Drop its entry so it doesn't linger for the life
    # of the browser. Idempotent: our own close_page may have removed it already,
    # and a targetId we don't track is simply a no-op delete.
    # An isolated page's context goes with it.
    tid = params["targetId"]
    state = page_gone(state, tid)
    {:noreply, %{state | sessions: Map.delete(state.sessions, tid)}}
  end

  def handle_info({:fetch_reply, _pid, tag, result}, state) do
    # A Fetch owner finished a request; reply to the caller parked on it. Unknown tag →
    # the caller already departed (an authenticate/4 caller whose :DOWN asked the owner
    # to drop the auth), or a request nobody waits on — ignore it.
    case Map.pop(state.pending, tag) do
      {nil, _} ->
        {:noreply, state}

      {{from, caller_ref, _pid}, pending} ->
        if caller_ref, do: Process.demonitor(caller_ref, [:flush])
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # An authenticate/4 caller we were monitoring went down while its auth was still
    # arming — typically because its 15s call timed out on a slow arm. Ask the owner to
    # drop that auth (matched by its tag, so a later auth by someone else is safe), so
    # the page can be authenticated again instead of being stuck on
    # :already_authenticated (#40). We do not reply — the caller is gone. The owner's
    # reply to the original request then finds no pending entry and is ignored.
    #
    # No demonitor here: a monitor is one-shot, and the runtime already removed it when
    # it delivered this :DOWN.
    case Enum.find(state.pending, fn {_tag, {_from, caller_ref, _pid}} -> caller_ref == ref end) do
      nil ->
        {:noreply, state}

      {tag, {_from, _ref, pid}} ->
        Fetch.request(pid, make_ref(), {:drop_auth, tag})
        {:noreply, %{state | pending: Map.delete(state.pending, tag)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Send `request` to the page's Fetch owner, starting it on first use, and park `from`
  # under a fresh tag until the owner's {:fetch_reply, …}.
  defp fetch_request(state, page, from, caller_ref, request) do
    case ensure_fetcher(state, page) do
      {:ok, pid, state} ->
        tag = make_ref()
        Fetch.request(pid, tag, request)
        {:ok, %{state | pending: Map.put(state.pending, tag, {from, caller_ref, pid})}}

      {:error, _} = error ->
        error
    end
  end

  # The page's Fetch owner: linked to us (crash-isolated, dies with the browser). It
  # stops by itself when the page's connection goes down or its session detaches, and
  # we stop it when we end the page (drop_fetcher/2).
  defp ensure_fetcher(state, %Page{target_id: tid} = page) do
    case Map.get(state.fetchers, tid) do
      nil ->
        opts = [conn: page.conn, session_id: page.session_id, target_id: tid, browser: self()]

        case Fetch.start_link(opts) do
          {:ok, pid} -> {:ok, pid, %{state | fetchers: Map.put(state.fetchers, tid, pid)}}
          {:error, _} = error -> error
        end

      pid ->
        {:ok, pid, state}
    end
  end

  # Fail every caller parked on Fetch owner `pid`, which exited with `reason`.
  defp fail_pending(state, pid, reason) do
    {gone, pending} = Map.split_with(state.pending, fn {_tag, {_, _, p}} -> p == pid end)

    Enum.each(gone, fn {_tag, {from, caller_ref, _pid}} ->
      if caller_ref, do: Process.demonitor(caller_ref, [:flush])
      GenServer.reply(from, {:error, fetch_exit_reason(reason)})
    end)

    %{state | pending: pending}
  end

  # An owner that stops :normal does so because its page went away.
  defp fetch_exit_reason(:normal), do: :noproc
  defp fetch_exit_reason(reason), do: reason

  @impl true
  def terminate(_reason, state) do
    # Stop the page and browser connections best-effort (a conn may already be
    # dying — its exit must not abort us before Chrome.stop/1, the no-orphan
    # guarantee). Closing browser_conn here makes teardown deterministic instead
    # of leaving it to stop reactively when its socket drops on Chrome exit.
    _ =
      if state.connected and Process.alive?(state.browser_conn) do
        # Connect-mode: we don't own Chrome, so closing the socket wouldn't reap the
        # tabs we opened. Close just OUR targets (best-effort; close_target tolerates
        # a dead conn), leaving Chrome and any pre-existing tabs untouched.
        Enum.each(Map.keys(state.sessions) ++ Map.keys(state.pages), fn tid ->
          discard_target(state.browser_conn, tid, Map.get(state.contexts, tid))
        end)
      end

    Enum.each(state.pages, fn {_tid, conn} -> safe_close(conn) end)
    safe_close(state.browser_conn)
    if state.chrome, do: Chrome.stop(state.chrome)
    :ok
  end

  # The browser connection went down. A clean close — `{:shutdown, {:ws_closed, _}}`,
  # the Connection's own graceful-stop contract when its socket drops (e.g. Chrome
  # going away on teardown) — is expected, so stop with a :shutdown reason and the
  # GenServer logs nothing. Any other reason is a genuine fault and stays loud.
  defp browser_down_reason({:shutdown, {:ws_closed, _}} = reason),
    do: {:shutdown, {:browser_connection_down, reason}}

  defp browser_down_reason(reason), do: {:browser_connection_down, reason}

  # ── page creation ───────────────────────────────────────────────────────────

  defp reply_dedicated_page(state, opts) do
    case open_page(state, opts) do
      {:ok, page, context_id} ->
        Telemetry.page(:start, %{
          target_id: page.target_id,
          transport: :dedicated,
          isolated: context_id != nil
        })

        state = %{
          state
          | pages: Map.put(state.pages, page.target_id, page.conn),
            contexts: put_context(state.contexts, page.target_id, context_id)
        }

        reply_armed_page(state, page, arm_requests(state, opts))

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # What a new page's Fetch owner must arm before the page is returned: the proxy's
  # login (browser launched with an authenticated `:proxy`), then the `:block` types
  # (already converted to CDP types by new_page/2).
  defp arm_requests(state, opts) do
    auth =
      if state.proxy_auth,
        do: [{:auth, %{credentials: state.proxy_auth, source: :proxy}}],
        else: []

    block =
      case Keyword.get(opts, :block, []) do
        [] -> []
        types -> [{:block, types, @arm_timeout}]
      end

    auth ++ block
  end

  # Arm the new page's Fetch modes before returning it, so the caller navigates straight
  # away (no manual authenticate/4 or block_resources/3). Done synchronously within
  # new_page — which already blocks the Browser for target creation + bootstrap — so it
  # awaits the owner's replies here instead of parking a caller in `pending`; all of
  # them share one @arm_timeout. The owner is recorded in `fetchers` like any other, so
  # interception can join it later and the drop-on-EXIT teardown applies unchanged. On
  # any arm failure the just-created page (never handed to the caller) is closed and the
  # error surfaced.
  defp reply_armed_page(state, page, []), do: {:reply, {:ok, page}, state}

  defp reply_armed_page(state, page, requests) do
    case ensure_fetcher(state, page) do
      {:ok, pid, state} ->
        deadline = System.monotonic_time(:millisecond) + @arm_timeout

        case arm_each(pid, requests, deadline) do
          :ok -> {:reply, {:ok, page}, state}
          {:error, reason} -> {:reply, {:error, reason}, close_failed_arm_page(state, page)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, close_failed_arm_page(state, page)}
    end
  end

  defp arm_each(_pid, [], _deadline), do: :ok

  defp arm_each(pid, [request | rest], deadline) do
    tag = make_ref()
    Fetch.request(pid, tag, request)

    case await_fetch_reply(pid, tag, max(deadline - System.monotonic_time(:millisecond), 0)) do
      :ok -> arm_each(pid, rest, deadline)
      {:error, _} = error -> error
    end
  end

  # The new page's Fetch arm failed; the just-created page was never handed to the caller, so
  # close its target + connection and drop it from `pages` (best-effort — either may
  # already be gone). Ending the target also stops its Fetch owner. Returns the updated
  # state for the {:reply, …} tuple.
  defp close_failed_arm_page(state, %Page{target_id: tid, session_id: nil, conn: conn}) do
    safe_close(conn)
    state = end_target(state, tid)
    %{state | pages: Map.delete(state.pages, tid)}
  end

  defp close_failed_arm_page(state, %Page{target_id: tid, session_id: sid}) do
    detach_session(state.browser_conn, sid)
    state = end_target(state, tid)
    %{state | sessions: Map.delete(state.sessions, tid)}
  end

  # Block (inside the new_page call) until the Fetch owner replies. It is linked and we
  # trap exits, so a crash arrives as {:EXIT, pid, _}. Bounded by `timeout` (what is left
  # of @arm_timeout); the caller then closes the page, which stops the owner. A late reply
  # or {:EXIT} for this pid arriving after we return is handled harmlessly by the
  # handle_info clauses.
  defp await_fetch_reply(pid, tag, timeout) do
    receive do
      {:fetch_reply, ^pid, ^tag, result} -> result
      {:EXIT, ^pid, reason} -> {:error, fetch_exit_reason(reason)}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp reply_session_page(state, opts) do
    case open_session_page(state, opts) do
      {:ok, page, context_id} ->
        Telemetry.page(:start, %{
          target_id: page.target_id,
          transport: :session,
          isolated: context_id != nil
        })

        sessions = Map.put(state.sessions, page.target_id, page.session_id)
        contexts = put_context(state.contexts, page.target_id, context_id)
        state = %{state | sessions: sessions, contexts: contexts}

        reply_armed_page(state, page, arm_requests(state, opts))

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp open_page(state, opts) do
    with {:ok, context_id} <- maybe_create_context(state.browser_conn, opts),
         {:ok, tid} <- create_target(state.browser_conn, context_id) do
      open_target(state, tid, context_id, opts)
    end
  end

  # `isolated: true` → a fresh browser context for the page; otherwise nil (the
  # browser's default context). `disposeOnDetach` makes Chrome dispose it if the
  # browser connection drops, so a VM that dies without terminate/2 (connect-mode)
  # doesn't leave it behind on a Chrome it doesn't own.
  defp maybe_create_context(browser_conn, opts) do
    if Keyword.get(opts, :isolated, false) do
      case Connection.call(
             browser_conn,
             "Target.createBrowserContext",
             %{"disposeOnDetach" => true},
             @create_timeout
           ) do
        {:ok, %{"browserContextId" => context_id}} -> {:ok, context_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  # Creates the page's target, in `context_id` when given. A failure disposes that
  # context: nothing else references it yet.
  defp create_target(browser_conn, context_id) do
    params =
      if context_id,
        do: %{"url" => "about:blank", "browserContextId" => context_id},
        else: %{"url" => "about:blank"}

    case Connection.call(browser_conn, "Target.createTarget", params, @create_timeout) do
      {:ok, %{"targetId" => tid}} ->
        {:ok, tid}

      {:error, reason} ->
        if context_id, do: dispose_context(browser_conn, context_id)
        {:error, reason}
    end
  end

  # The target exists now, so any failure past this point must close it (and the
  # page connection, if opened) — otherwise we leak a Chrome tab/socket that
  # isn't tracked in state.pages and can't be cleaned up deterministically.
  defp open_target(state, tid, context_id, opts) do
    page_url = "ws://#{Protocol.bracket_host(state.host)}:#{state.port}/devtools/page/#{tid}"

    case Connection.start_link(page_url) do
      {:ok, conn} ->
        case bootstrap_page(conn, opts) do
          :ok ->
            {:ok, %Page{browser: self(), conn: conn, target_id: tid}, context_id}

          {:error, reason} ->
            safe_close(conn)
            discard_target(state.browser_conn, tid, context_id)
            {:error, reason}
        end

      {:error, reason} ->
        discard_target(state.browser_conn, tid, context_id)
        {:error, reason}
    end
  end

  # The session transport: create a target, attach with `flatten: true` (its
  # frames then arrive on the browser connection tagged with the sessionId), and
  # bootstrap it over that shared connection. On any failure NEVER `safe_close`
  # browser_conn — it is shared by every other session.
  defp open_session_page(state, opts) do
    with {:ok, context_id} <- maybe_create_context(state.browser_conn, opts),
         {:ok, tid} <- create_target(state.browser_conn, context_id) do
      attach_session(state, tid, context_id, opts)
    end
  end

  defp attach_session(state, tid, context_id, opts) do
    case Connection.call(
           state.browser_conn,
           "Target.attachToTarget",
           %{"targetId" => tid, "flatten" => true},
           @create_timeout
         ) do
      {:ok, %{"sessionId" => sid}} ->
        case bootstrap_page(state.browser_conn, sid, opts) do
          :ok ->
            page = %Page{browser: self(), conn: state.browser_conn, target_id: tid, session_id: sid}
            {:ok, page, context_id}

          {:error, reason} ->
            detach_session(state.browser_conn, sid)
            discard_target(state.browser_conn, tid, context_id)
            {:error, reason}
        end

      {:error, reason} ->
        discard_target(state.browser_conn, tid, context_id)
        {:error, reason}
    end
  end

  # Detach a session on the browser connection, ignoring failures.
  defp detach_session(browser_conn, session_id) do
    _ =
      Connection.call(
        browser_conn,
        "Target.detachFromTarget",
        %{"sessionId" => session_id},
        @create_timeout
      )

    :ok
  end

  defp bootstrap_page(conn, opts), do: bootstrap_page(conn, nil, opts)

  defp bootstrap_page(conn, session_id, opts) do
    with {:ok, _} <- bcall(conn, session_id, "Page.enable", %{}),
         {:ok, _} <- bcall(conn, session_id, "Runtime.enable", %{}),
         {:ok, _} <-
           bcall(conn, session_id, "Page.setLifecycleEventsEnabled", %{"enabled" => true}) do
      set_dialogs(conn, session_id, Keyword.get(opts, :dialogs, :accept))
    end
  end

  # One bootstrap CDP call, scoped to `session_id` (nil for a dedicated page).
  defp bcall(conn, session_id, method, params) do
    Connection.call(conn, method, params, @bootstrap_timeout, session_id: session_id)
  end

  # :accept is every connection's default, so only another policy costs a call.
  defp set_dialogs(_conn, _session_id, :accept), do: :ok

  defp set_dialogs(conn, session_id, policy),
    do: Connection.set_dialogs(conn, session_id, policy, @bootstrap_timeout)

  # One of this browser's open pages: a :dedicated page by its own connection, a
  # :session page by its session on the browser connection.
  defp own_page?(state, tid, conn, nil), do: Map.get(state.pages, tid) == conn

  defp own_page?(state, tid, conn, sid),
    do: conn == state.browser_conn and Map.get(state.sessions, tid) == sid

  defp drop_conn(pages, pid) do
    pages |> Enum.reject(fn {_tid, conn} -> conn == pid end) |> Map.new()
  end

  defp drop_value(map, pid) do
    map |> Enum.reject(fn {_k, v} -> v == pid end) |> Map.new()
  end

  # Close a CDP target on the browser connection, ignoring failures (the browser
  # conn may be gone, or the target already closed).
  defp close_target(browser_conn, tid) do
    _ = Connection.call(browser_conn, "Target.closeTarget", %{"targetId" => tid}, @create_timeout)
    :ok
  end

  # Ends a target we opened: disposing its own context closes it too; a target in
  # the default context is closed directly. Best-effort, like close_target/2.
  defp discard_target(browser_conn, _tid, context_id) when is_binary(context_id),
    do: dispose_context(browser_conn, context_id)

  defp discard_target(browser_conn, tid, nil), do: close_target(browser_conn, tid)

  defp dispose_context(browser_conn, context_id) do
    _ =
      Connection.call(
        browser_conn,
        "Target.disposeBrowserContext",
        %{"browserContextId" => context_id},
        @create_timeout
      )

    :ok
  end

  # Ends one of our pages' targets (see discard_target/3) and forgets its context.
  defp end_target(state, tid) do
    discard_target(state.browser_conn, tid, Map.get(state.contexts, tid))
    drop_fetcher(%{state | contexts: Map.delete(state.contexts, tid)}, tid)
  end

  # The page's target is already gone: dispose its context, if it had one, and forget
  # its Fetch owner. The dispose runs off the Browser process: this is called
  # from handle_info, where a Chrome that is alive but not answering would otherwise
  # block every other page op for the call timeout, once per page that went.
  defp page_gone(state, tid) do
    state = drop_fetcher(state, tid)

    case Map.pop(state.contexts, tid) do
      {nil, _} ->
        state

      {context_id, contexts} ->
        dispose_context_async(state.browser_conn, context_id)
        %{state | contexts: contexts}
    end
  end

  # Best-effort, like dispose_context/2. Should the browser connection drop before it
  # runs, `disposeOnDetach` makes Chrome dispose the context anyway.
  defp dispose_context_async(browser_conn, context_id) do
    _ =
      Task.start(fn ->
        ProcessLabel.set({:cdp_context_dispose, context_id})
        dispose_context(browser_conn, context_id)
      end)

    :ok
  end

  # The page ended, and its Fetch domain with it: stop its Fetch owner, if any. Callers
  # still parked on it are failed by its {:EXIT}.
  defp drop_fetcher(state, tid) do
    case Map.pop(state.fetchers, tid) do
      {nil, _} ->
        state

      {pid, fetchers} ->
        Fetch.stop(pid)
        %{state | fetchers: fetchers}
    end
  end

  defp put_context(contexts, _tid, nil), do: contexts
  defp put_context(contexts, tid, context_id), do: Map.put(contexts, tid, context_id)

  # Stop a page connection from teardown, where nothing may raise or exit.
  # `Connection.close/1` is already `:ok` on a gone process; the rescue and catch are
  # a backstop so a surprise there can't skip the Chrome.stop/1 that follows.
  defp safe_close(conn) do
    if Process.alive?(conn), do: Connection.close(conn)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
