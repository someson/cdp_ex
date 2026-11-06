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

  This is an internal building block; use the `CDPEx.Page` functions.
  """

  use GenServer

  alias CDPEx.Connection
  alias CDPEx.ProcessLabel

  require Logger

  @call_timeout 10_000
  @max_tracked 1024
  @events ["Fetch.requestPaused", "Fetch.authRequired"]

  defstruct [
    :conn,
    :session_id,
    :browser,
    # nil | %{username, password, source, tag}
    auth: nil,
    # nil | %{owner, ref, patterns, matchers}
    intercept: nil,
    # nil | [CDP resource type string], deduplicated
    block: nil,
    subscribed: false,
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
          {:auth, %{username: String.t(), password: String.t(), source: atom()}}
          | {:drop_auth, reference()}
          | {:intercept, pid(), [map()], timeout()}
          | {:release_intercept, timeout()}
          | {:block, [String.t()], timeout()}

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
        {:cdp_event, conn, "Fetch.requestPaused", %{"requestId" => request_id} = params, sid} =
          event,
        %__MODULE__{conn: conn, session_id: sid} = state
      ) do
    case decide(state, params) do
      :block ->
        _ =
          call(state, "Fetch.failRequest", %{
            "requestId" => request_id,
            "errorReason" => "BlockedByClient"
          })

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
        %__MODULE__{conn: conn, session_id: sid, auth: %{} = auth} = state
      ) do
    {response, attempts} =
      auth_decision(auth.source, state.attempts, request_id, params["authChallenge"] || %{},
        username: auth.username,
        password: auth.password
      )

    _ =
      call(state, "Fetch.continueWithAuth", %{
        "requestId" => request_id,
        "authChallengeResponse" => response
      })

    {:noreply, %{state | attempts: attempts}}
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

  # Includes Fetch.authRequired while auth is off: it isn't ours to answer (a caller
  # that enabled handleAuthRequests itself answers it).
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: the connection may already be gone (Connection.call and
    # safe_unsubscribe both tolerate that), leaving nothing to disable.
    _ =
      if not state.detached and any_mode?(state),
        do: call(state, "Fetch.disable", %{})

    _ = if state.subscribed, do: safe_unsubscribe(state)
    :ok
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
  defp rearm(prev, next, timeout) do
    case enable_params(next.auth, next.intercept && next.intercept.patterns, next.block) do
      nil -> disable(prev, next, timeout)
      params -> enable(prev, next, params, timeout)
    end
  end

  defp disable(%__MODULE__{auth: nil, intercept: nil, block: nil}, next, _timeout), do: {:ok, next}

  defp disable(_prev, next, timeout) do
    case call(next, "Fetch.disable", %{}, timeout) do
      {:ok, _} -> {:ok, next}
      {:error, reason} -> {{:error, reason}, next}
    end
  end

  defp enable(prev, next, params, timeout) do
    case ensure_subscribed(next, timeout) do
      {:ok, next} ->
        case call(next, "Fetch.enable", params, timeout) do
          {:ok, _} -> {:ok, next}
          {:error, reason} -> arm_failed(reason, %{prev | subscribed: true})
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
    methods = if state.session_id, do: ["Target.detachedFromTarget" | @events], else: @events

    Enum.reduce_while(methods, {:ok, state}, fn method, {:ok, acc} ->
      case Connection.subscribe(acc.conn, method, timeout, session_id: acc.session_id) do
        :ok -> {:cont, {:ok, %{acc | subscribed: true}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The page connection died, or a :session page's session detached, mid-arm (a
  # close/arm race) — no log.
  defp benign?(:noproc), do: true
  defp benign?({tag, _}) when tag in [:ws_closed, :session_closed], do: true
  defp benign?(_), do: false

  # ── pure helpers ────────────────────────────────────────────────────────────

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
  # forward it to the interception owner, or let it through. With auth and block off,
  # Chrome paused exactly the owner's patterns. Otherwise more requests pause at the
  # Request stage than the owner asked for, so match them here; the Response stage
  # only has the owner's patterns.
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

  defp owners?(%__MODULE__{auth: nil, block: nil}, _params), do: true

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
  @spec auth_decision(atom(), map(), String.t(), map(), keyword()) :: {map(), map()}
  def auth_decision(source_filter, attempts, request_id, challenge, creds) do
    cond do
      not source_match?(source_filter, challenge["source"]) ->
        {%{"response" => "Default"}, attempts}

      Map.get(attempts, request_id, 0) >= 1 ->
        # Already answered once; a repeat means the credentials were rejected —
        # cancel rather than loop forever.
        {%{"response" => "CancelAuth"}, Map.delete(attempts, request_id)}

      true ->
        response = %{
          "response" => "ProvideCredentials",
          "username" => Keyword.fetch!(creds, :username),
          "password" => Keyword.fetch!(creds, :password)
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

  defp call(state, method, params, timeout \\ @call_timeout) do
    Connection.call(state.conn, method, params, timeout, session_id: state.session_id)
  end

  defp safe_unsubscribe(state) do
    for method <- ["Target.detachedFromTarget" | @events] do
      Connection.unsubscribe(state.conn, method)
    end
  end
end
