defmodule CDPEx.Pool do
  @moduledoc """
  A fixed-size pool of reusable `CDPEx.Browser` processes.

  Launching Chrome is expensive — a cold start can take several seconds on a
  constrained host, with a fresh profile each time. A pool keeps browsers warm
  and hands them out for reuse, so a per-job fetch no longer pays a launch on
  every call.

      {:ok, pool} = CDPEx.Pool.start_link(size: 2, launch_opts: [headless: true])

      CDPEx.Pool.with_page(pool, fn page ->
        {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
        CDPEx.Page.html(page)
      end)

  Browsers are launched **lazily** up to `:size` and reused thereafter. Each
  browser is lent to up to `:pages_per_browser` callers at once (one by default);
  a checkout goes to the least-loaded warm browser with a free slot, and a new
  browser is launched only when every warm one is full. `checkout/2` blocks (up
  to `:checkout_timeout`) when every slot is taken. The
  pool is resilient: a caller that crashes while holding a browser has it returned
  automatically, and a browser that crashes is dropped and relaunched on demand —
  so `:size` self-heals. Put the pool under your supervision tree; its
  `terminate/2` stops every browser, reaping Chrome.

  Browser launches are **asynchronous** — each cold start (a cold Chrome can take a
  few seconds) runs in its own task, so the pool keeps serving checkouts, checkins,
  and timeouts while browsers warm up, and a pool growing to `:size` under load
  launches them concurrently. `:checkout_timeout` is honored even during warmup.

  ## Options

    * `:size` — maximum number of browsers (default `1`)
    * `:pages_per_browser` — how many checkouts share one browser at a time (default
      `1`). `size: 2, pages_per_browser: 4` serves 8 parallel jobs on 2 Chromes, for
      less memory and fewer jobs per second than 8 × 1. Sharing jobs should use
      `with_page/3`: its isolated context keeps their cookies and storage apart,
      while a holder of the whole browser (`with_browser/3`, `checkout/2`) can stop
      it or change browser-wide state under the others. Page setup on one browser
      runs one at a time, so it queues behind the other holders'.
    * `:launch_opts` — options passed to each `CDPEx.Browser` (see `CDPEx.Chrome`); any
      `:owner` here is ignored — the pool owns its browsers and sets it itself
    * `:checkout_timeout` — ms to wait for a free browser (default `5_000`)
    * `:name` — registers the pool process
  """

  use GenServer

  alias CDPEx.Browser
  alias CDPEx.Exits
  alias CDPEx.ProcessLabel
  alias CDPEx.Proxy

  require Logger

  @default_size 1
  @default_checkout_timeout 5_000
  # Per-launch ceiling for terminate/2's drain of in-flight launches (see terminate/2).
  @launch_drain_timeout 5_000

  defstruct [
    :size,
    :launch_opts,
    :start_fun,
    :task_sup,
    pages_per_browser: 1,
    # browser => number of checkouts holding it, for every adopted browser.
    loads: %{},
    # owner monitor ref => {browser, owner}, one per checkout.
    holders: %{},
    waiting: :queue.new(),
    # task_ref => true for each in-flight async launch; counts toward :size so
    # map_size(loads) + map_size(launching) never exceeds it.
    launching: %{}
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a pool. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, pool_opts} = Keyword.split(opts, [:name])

    if !Keyword.has_key?(pool_opts, :start_fun),
      do: Browser.validate_launch_opts!(Keyword.get(pool_opts, :launch_opts, []))

    validate_pages_per_browser!(Keyword.get(pool_opts, :pages_per_browser, 1))

    GenServer.start_link(__MODULE__, pool_opts, gen_opts)
  end

  @doc false
  def child_spec(opts) do
    # Derive a distinct id from :id/:name so several pools can run under one
    # supervisor without colliding on the default __MODULE__ id. terminate/2 stops
    # every browser sequentially (each takes a few seconds to reap Chrome), so give
    # the supervisor headroom over the GenServer 5s default.
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))
    %{id: id, start: {__MODULE__, :start_link, [opts]}, shutdown: 30_000}
  end

  @doc """
  Borrows a browser, blocking up to `timeout` ms when all are busy.

  With `:pages_per_browser` above 1 the browser may be lent to other callers at
  the same time, and one caller may get the same browser from several checkouts;
  each checkout takes one slot and each `checkin/2` frees one.

  Returns `{:ok, browser}`, `{:error, :timeout}`, or `{:error, reason}` if a
  browser had to be launched and failed — a launch error is reported to a waiting
  caller and is generally worth retrying. A caller still waiting when the pool stops
  gets `{:error, :noproc}`. **Always** `checkin/2` it when done — or use
  `with_browser/3` / `with_page/3`, which do that for you.

  `timeout` is integer ms in `0..4_294_967_295` or `:infinity`; anything else
  raises `ArgumentError` in the caller and leaves the pool untouched. `0` takes a
  free browser if there is one and returns `{:error, :timeout}` otherwise.
  """
  @spec checkout(GenServer.server(), timeout()) :: {:ok, pid()} | {:error, term()}
  def checkout(pool, timeout \\ @default_checkout_timeout) do
    # Validate here, in the caller: a bad value reaching the pool's timer would crash
    # the pool and every warm browser it owns.
    validate_timeout!(timeout)

    # Wait indefinitely on the outer call; the pool's own per-request timer is the
    # authoritative timeout (it removes the waiter and replies {:error, :timeout}).
    # This avoids a stale waiter when a slow launch blocks the pool past a tight
    # outer deadline. A pool that stops mid-wait surfaces as {:error, :noproc}.
    GenServer.call(pool, {:checkout, timeout}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {:shutdown, _} -> {:error, :noproc}
    :exit, {{:shutdown, _}, _} -> {:error, :noproc}
    # A pool that crashed mid-wait is just as gone.
    :exit, {reason, {GenServer, :call, _}} when reason != :calling_self -> {:error, :noproc}
  end

  @doc """
  Returns a browser borrowed with `checkout/2`.

  Only the process that checked the browser out can return it. A checkin from any
  other process is ignored with a warning, so it can't hand a browser still in use
  to the next caller; the browser stays with its holder until the holder checks it
  in or exits. A caller holding several slots on the browser frees one per checkin.
  """
  @spec checkin(GenServer.server(), pid()) :: :ok
  def checkin(pool, browser), do: GenServer.cast(pool, {:checkin, browser, self()})

  @doc """
  Runs `fun` with a checked-out browser, returning it afterwards (even if `fun`
  raises). Returns `fun`'s value, or `{:error, reason}` if no browser was free.
  """
  @spec with_browser(GenServer.server(), (pid() -> result), timeout()) ::
          result | {:error, term()}
        when result: var
  def with_browser(pool, fun, timeout \\ @default_checkout_timeout) when is_function(fun, 1) do
    case checkout(pool, timeout) do
      {:ok, browser} ->
        try do
          fun.(browser)
        after
          checkin(pool, browser)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Runs `fun` with a fresh page on a pooled browser, cleaning up the page and
  returning the browser afterwards. The pooled counterpart of `CDPEx.with_page/3`
  — it reuses a warm browser instead of launching one per call.

  Each call runs in its own browser context (`isolated: true`, see
  `CDPEx.Browser.new_page/2`): cookies, `localStorage` and cache set by one job
  are gone for the next, and the context is disposed with the page. Pass
  `isolated: false` to share the browser's default context across jobs (a login
  kept between calls, say).

  `opts` are forwarded to `CDPEx.with_page/3` (e.g. `:dialogs`, or
  `:deadline`, which closes the page — not the pooled browser — and whose clock
  starts after checkout, so it doesn't cover the wait for a free browser); pass
  `:checkout_timeout` to bound that wait.
  Returns `fun`'s value, or `{:error, reason}`.

  A `{:error, {:timeout, :new_page}}` means the browser could not serve the page in
  time and may still open it later, unowned; that browser goes back into the pool, so
  repeated timeouts can pile pages up on it. Restart the pool if they recur.
  """
  @spec with_page(GenServer.server(), (CDPEx.Page.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: var
  def with_page(pool, fun, opts \\ []) when is_function(fun, 1) do
    {timeout, page_opts} = Keyword.pop(opts, :checkout_timeout, @default_checkout_timeout)
    page_opts = Keyword.put_new(page_opts, :isolated, true)
    with_browser(pool, fn browser -> CDPEx.with_page(browser, fun, page_opts) end, timeout)
  end

  @doc "Stops the pool, stopping every browser (and reaping Chrome). `:ok` if it is already gone."
  @spec stop(GenServer.server()) :: :ok
  def stop(pool) do
    GenServer.stop(pool, :normal)
  catch
    :exit, {reason, {GenServer, :stop, _}} when reason != :calling_self ->
      Exits.warn_unclean_stop("CDPEx.Pool", reason)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  # launch_opts may carry the :proxy credentials: mask them in crash reports and
  # :sys.get_status/1. GenServer declares format_status/1 from Elixir 1.17 on (OTP
  # calls it either way), hence the guard.
  if {:format_status, 1} in GenServer.behaviour_info(:callbacks), do: @impl(true)
  @doc false
  def format_status(%{state: %__MODULE__{launch_opts: opts} = state} = status) when is_list(opts) do
    if Keyword.has_key?(opts, :proxy),
      do: %{
        status
        | state: %{state | launch_opts: Keyword.update!(opts, :proxy, &Proxy.redact_option/1)}
      },
      else: status
  end

  def format_status(status), do: status

  @impl true
  def init(opts) do
    # Trap exits: browsers are start_linked, so a browser crash arrives as an
    # {:EXIT, _, _} we handle (drop + relaunch on demand) rather than taking the
    # pool down, and terminate/2 runs to reap Chrome.
    Process.flag(:trap_exit, true)

    size = Keyword.get(opts, :size, @default_size)
    ProcessLabel.set({:cdp_pool, size})

    # Owns the async browser-launch tasks (see start_one_launch/1). Linked to the pool, so
    # it — and any in-flight launches — go down with us.
    {:ok, task_sup} = Task.Supervisor.start_link()

    {:ok,
     %__MODULE__{
       size: size,
       launch_opts: Keyword.get(opts, :launch_opts, []),
       pages_per_browser: Keyword.get(opts, :pages_per_browser, 1),
       start_fun: Keyword.get(opts, :start_fun, &Browser.start_link/1),
       task_sup: task_sup
     }}
  end

  @impl true
  def handle_call({:checkout, timeout}, from, state) do
    # Enqueue then dispatch: a request is served at once if there's capacity,
    # otherwise it waits in the queue for a checkin/crash to free a browser.
    timer = arm_timeout(from, timeout)
    {:noreply, dispatch(%{state | waiting: :queue.in({from, timer}, state.waiting)})}
  end

  @impl true
  def handle_cast({:checkin, browser, caller}, state) do
    held = Enum.find(state.holders, fn {_ref, holder} -> holder == {browser, caller} end)

    cond do
      held != nil ->
        {ref, _holder} = held
        {:noreply, state |> release(ref) |> dispatch()}

      # Not checked out (already returned, or dropped after a crash): nothing to do.
      Map.get(state.loads, browser, 0) == 0 ->
        {:noreply, state}

      true ->
        Logger.warning(
          "[CDPEx.Pool] ignored checkin of #{inspect(browser)} from #{inspect(caller)}: " <>
            "it is checked out by another process"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:checkout_timeout, from}, state) do
    case remove_waiter(state.waiting, from) do
      {:ok, _timer, waiting} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: waiting}}

      :error ->
        # Served between the timer firing and now — nothing to do.
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, %__MODULE__{launching: launching} = state)
      when is_reference(ref) and is_map_key(launching, ref) do
    # An async launch task returned (a started browser, or a start error). Stop monitoring
    # it — the task's own :DOWN follows, so flush it — then act on the result.
    Process.demonitor(ref, [:flush])
    state = %{state | launching: Map.delete(launching, ref)}

    case result do
      {:ok, browser} ->
        {:noreply, browser_launched(state, browser)}

      {:error, reason} ->
        {:noreply, launch_failed(state, reason)}

      # A start_fun that returns something other than {:ok, _} / {:error, _} (e.g. :ignore,
      # valid per GenServer.on_start) is treated as a failed launch rather than crashing us.
      other ->
        {:noreply, launch_failed(state, {:launch_crashed, {:unexpected_launch_result, other}})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{launching: launching} = state)
      when is_map_key(launching, ref) do
    # A launch task crashed before returning a result (it never sent {ref, result}).
    # Tagged, so the arbitrary crash term stays inside CDPEx.error_reason/0.
    state = %{state | launching: Map.delete(launching, ref)}
    {:noreply, launch_failed(state, {:launch_crashed, reason})}
  end

  def handle_info({:DOWN, ref, :process, _owner, _reason}, state)
      when is_map_key(state.holders, ref) do
    # A checkout owner died without checking in — reclaim that checkout's slot.
    {:noreply, state |> release(ref) |> dispatch()}
  end

  def handle_info({:EXIT, task_sup, reason}, %__MODULE__{task_sup: task_sup} = state) do
    # Our launch-task supervisor died — without it we can't launch browsers (a checkout
    # would crash on async_nolink to a dead sup). Stop with an attributable reason so our
    # own supervisor restarts us with a fresh task_sup, rather than limping on as a zombie.
    {:stop, {:task_sup_down, reason}, state}
  end

  def handle_info({:EXIT, browser, _reason}, state) do
    # A pooled browser stopped/crashed. Drop it; capacity frees up, so dispatch
    # can serve a waiting caller by launching a replacement.
    {:noreply, state |> drop(browser) |> dispatch()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Reply to anyone still blocked in checkout/2 first, so they get a clean
    # {:error, :noproc} without waiting on the (possibly multi-second) serial
    # browser teardown below.
    Enum.each(:queue.to_list(state.waiting), fn {from, timer} ->
      _ = cancel_timer(timer)
      GenServer.reply(from, {:error, :noproc})
    end)

    Enum.each(Map.keys(state.loads), &safe_stop/1)

    # An in-flight launch may finish a browser we never adopted: once the task runs
    # Process.unlink/1, that browser is linked to nobody, so killing task_sup won't reap it.
    # task_sup is still alive here, so each launch can still deliver — wait briefly per ref to
    # catch a just-completed one and stop it (or its terminal :DOWN/error), so a shutdown
    # mid-launch doesn't orphan Chrome. One SHARED deadline caps the whole drain at
    # @launch_drain_timeout regardless of :size, so it can't blow past child_spec's
    # shutdown: 30_000 (which would let the supervisor :brutal_kill us mid-drain).
    drain_deadline = System.monotonic_time(:millisecond) + @launch_drain_timeout

    Enum.each(Map.keys(state.launching), fn ref ->
      remaining = max(drain_deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, {:ok, browser}} -> safe_stop(browser)
        {^ref, _other} -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        remaining ->
          # Budget spent before this launch delivered — its browser (if it completed) may
          # leak. Surface it rather than leaking silently. (remaining == 0 once the shared
          # deadline is used up, so later refs are skipped without a spurious wait.)
          if remaining > 0 do
            Logger.warning(
              "[CDPEx.Pool] a browser launch didn't complete within the shutdown drain; its Chrome may be orphaned"
            )
          end
      end
    end)

    :ok
  end

  # ── pool mechanics ──────────────────────────────────────────────────────────

  # Serve queued waiters: hand out free slots on warm browsers, then start launches
  # (concurrently, up to :size) for any still-waiting callers not already covered by an
  # in-flight launch. Launches run in tasks, so the pool stays responsive while Chrome warms
  # up. A free warm slot always wins over a launch: a cold start costs seconds.
  defp dispatch(state) do
    state |> serve_available() |> start_launches()
  end

  # Assign free slots to the head of the queue, FIFO, least-loaded browser first, until
  # either runs out.
  defp serve_available(state) do
    with browser when browser != nil <- least_loaded(state),
         {{:value, waiter}, rest} <- :queue.out(state.waiting) do
      %{state | waiting: rest} |> assign(browser, waiter) |> serve_available()
    else
      _ -> state
    end
  end

  defp least_loaded(%__MODULE__{loads: loads, pages_per_browser: per}) do
    case Enum.filter(loads, fn {_browser, load} -> load < per end) do
      [] -> nil
      free -> free |> Enum.min_by(fn {_browser, load} -> load end) |> elem(0)
    end
  end

  # Start enough launches to cover the still-uncovered waiters (each covers
  # :pages_per_browser of them), bounded by free capacity so adopted browsers + in-flight
  # launches never exceed :size. Launches are anonymous: each browser joins `loads` on
  # success and the next dispatch serves waiters FIFO.
  defp start_launches(%__MODULE__{size: size, launching: launching} = state) do
    capacity = size - map_size(state.loads) - map_size(launching)
    uncovered = :queue.len(state.waiting) - covered(state)
    needed = div(uncovered + state.pages_per_browser - 1, state.pages_per_browser)
    n = max(min(capacity, needed), 0)

    if n > 0, do: Enum.reduce(1..n, state, fn _, acc -> start_one_launch(acc) end), else: state
  end

  # Waiters the in-flight launches will serve once they land.
  defp covered(state), do: map_size(state.launching) * state.pages_per_browser

  # Launch a browser in a monitored task. async_nolink keeps a launch crash from taking the
  # pool down (we get its {:DOWN}); the task start_links the browser then unlinks it so the
  # POOL adopts it on the result — a browser linked to the ephemeral task would lose the
  # pool's crash handling. Keyed by the task ref to correlate the result / crash.
  defp start_one_launch(%__MODULE__{} = state) do
    pool = self()

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        ProcessLabel.set({:cdp_pool_launch, pool})
        launch(state.start_fun, state.launch_opts, pool)
      end)

    %{state | launching: Map.put(state.launching, task.ref, true)}
  end

  defp launch(start_fun, launch_opts, pool) do
    # Pass `owner: pool` so an adopted browser's owner-death self-reap targets the pool, not
    # this throwaway task (the default Browser honours it; an injected start_fun ignores it).
    case start_fun.(Keyword.put(launch_opts, :owner, pool)) do
      {:ok, browser} = ok ->
        # Detach from this (about-to-exit) task so the pool, not the task, owns the link.
        Process.unlink(browser)
        ok

      other ->
        other
    end
  end

  # Adopt a freshly launched browser: link it to the pool (the task unlinked it), add it to
  # `loads` with no holders, and dispatch so a waiter is served. If it died in the unlink→adopt
  # gap, alive? routes it through launch_failed rather than handing a dead pid to a waiter;
  # a death right after link/1 surfaces as an {:EXIT, browser, _} the EXIT clause reconciles.
  defp browser_launched(state, browser) do
    if Process.alive?(browser) do
      Process.link(browser)

      dispatch(%{state | loads: Map.put(state.loads, browser, 0)})
    else
      launch_failed(state, :noproc)
    end
  end

  # A launch failed (start error or task crash). Surface the reason to the head waiter ONLY
  # when this failure leaves one uncovered — i.e. the in-flight launches left can serve fewer
  # waiters than are queued. If every waiter is still covered by another in-flight launch (e.g. this failed
  # launch's waiter already timed out and left the queue), don't spuriously fail a live
  # waiter — let the other launches serve them. Replying on a genuine shortfall also bounds a
  # relaunch loop on persistent failure (each failure consumes one waiter).
  defp launch_failed(state, reason) do
    if covered(state) < :queue.len(state.waiting) do
      case :queue.out(state.waiting) do
        {{:value, {from, timer}}, rest} ->
          _ = cancel_timer(timer)
          GenServer.reply(from, {:error, reason})
          dispatch(%{state | waiting: rest})

        {:empty, _} ->
          dispatch(state)
      end
    else
      dispatch(state)
    end
  end

  # Give the waiter a slot on `browser`, monitor the owner (auto-checkin on its death),
  # cancel the wait timer, and reply.
  defp assign(state, browser, {from, timer}) do
    _ = cancel_timer(timer)
    owner = elem(from, 0)
    ref = Process.monitor(owner)
    GenServer.reply(from, {:ok, browser})

    %{
      state
      | loads: Map.update!(state.loads, browser, &(&1 + 1)),
        holders: Map.put(state.holders, ref, {browser, owner})
    }
  end

  # Free the slot of the checkout monitored by `ref` (a checkin, or an owner's death).
  defp release(state, ref) do
    case Map.pop(state.holders, ref) do
      {nil, _holders} ->
        state

      {{browser, _owner}, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}

        # Don't keep offering an already-dead browser (its {:EXIT} may not be processed
        # yet), or dispatch could hand a dead pid to a waiter. Drop it instead; the {:EXIT}
        # path reconciles anything this misses.
        if Process.alive?(browser),
          do: %{state | loads: Map.update!(state.loads, browser, &(&1 - 1))},
          else: drop(state, browser)
    end
  end

  # Remove a dead browser and every checkout holding it.
  defp drop(state, browser) do
    {gone, holders} = Map.split_with(state.holders, fn {_ref, {b, _owner}} -> b == browser end)
    Enum.each(Map.keys(gone), &Process.demonitor(&1, [:flush]))
    %{state | holders: holders, loads: Map.delete(state.loads, browser)}
  end

  defp remove_waiter(waiting, from) do
    case List.keytake(:queue.to_list(waiting), from, 0) do
      {{^from, timer}, rest} -> {:ok, timer, :queue.from_list(rest)}
      nil -> :error
    end
  end

  defp validate_pages_per_browser!(n) when is_integer(n) and n > 0, do: :ok

  defp validate_pages_per_browser!(other) do
    raise ArgumentError,
          "invalid :pages_per_browser #{inspect(other)} (expected a positive integer)"
  end

  # The upper bound is Process.send_after/3's limit; past it the pool's timer would crash.
  defp validate_timeout!(:infinity), do: :ok
  defp validate_timeout!(timeout) when is_integer(timeout) and timeout in 0..4_294_967_295, do: :ok

  defp validate_timeout!(other) do
    raise ArgumentError,
          "invalid :checkout_timeout #{inspect(other)} " <>
            "(expected integer ms in 0..4_294_967_295 or :infinity)"
  end

  defp arm_timeout(_from, :infinity), do: nil

  defp arm_timeout(from, timeout) when is_integer(timeout) do
    Process.send_after(self(), {:checkout_timeout, from}, timeout)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp safe_stop(browser) do
    if Process.alive?(browser), do: Browser.stop(browser)
    :ok
  end
end
