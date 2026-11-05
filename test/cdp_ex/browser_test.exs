defmodule CDPEx.BrowserTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.Browser
  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page

  describe "new_page/2 transport validation" do
    test "an unsupported :transport returns a structured error instead of crashing" do
      # The validation runs before any Chrome/connection I/O, so we can drive the
      # callback directly: a bad arg must yield a {:reply, ...} (the browser stays
      # up), not a raised CaseClauseError (which would take the GenServer — and
      # every page it owns — down).
      state = %Browser{}

      assert {:reply, {:error, {:invalid_transport, :bogus}}, ^state} =
               Browser.handle_call({:new_page, [transport: :bogus]}, {self(), make_ref()}, state)
    end

    test "a :session page is rejected when the browser has authenticated-proxy creds" do
      # An authenticated proxy auto-arms per-page Fetch, which only works on :dedicated
      # pages — the rejection fires before any I/O, so drive the callback directly.
      state = %Browser{proxy_auth: %{username: "u", password: "p"}}

      assert {:reply, {:error, {:unsupported_transport, :session}}, ^state} =
               Browser.handle_call({:new_page, [transport: :session]}, {self(), make_ref()}, state)
    end

    test "a :dedicated page is rejected on a connected (chrome-less) browser" do
      # Connect-mode can't open a dedicated page yet (its socket would have to target
      # the remote host); the rejection keys on `connected`, before any I/O.
      state = %Browser{connected: true}

      assert {:reply, {:error, {:unsupported_transport, :dedicated}}, ^state} =
               Browser.handle_call(
                 {:new_page, [transport: :dedicated]},
                 {self(), make_ref()},
                 state
               )
    end
  end

  describe "launch/1 :proxy validation" do
    test "a malformed :proxy fails the launch with {:invalid_proxy, _} (no Chrome launched)" do
      # apply_proxy runs before Chrome.launch in init/1, so a bad proxy stops init early.
      # start_link's failing init also link-exits the caller (as any launch failure does),
      # so trap exits to observe the {:error, _} return rather than be killed.
      Process.flag(:trap_exit, true)
      assert {:error, {:invalid_proxy, _}} = Browser.start_link(proxy: "not a url")
    end

    test "rejects :proxy combined with a full :args override (the flag would be dropped)" do
      # :proxy appends --proxy-server to :extra_args, which an :args override discards;
      # arming auth for a proxy Chrome never received is worse than a no-op, so reject.
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_proxy, :args_override}} =
               Browser.start_link(proxy: "http://host:8080", args: ["--headless=new"])
    end

    test "combining :proxy with :connect is rejected without launching Chrome" do
      # --proxy-server is a launch flag; connect-mode launches no Chrome, so it could
      # never take effect. init/1 rejects the combination before any connect attempt.
      Process.flag(:trap_exit, true)

      assert {:error, {:unsupported_with_connect, :proxy}} =
               Browser.start_link(
                 connect: "ws://127.0.0.1:1/devtools/browser/x",
                 proxy: "http://u:p@host:8080"
               )
    end
  end

  describe "session pruning" do
    test "a Target.detachedFromTarget event drops that session, keeping siblings" do
      # The Browser subscribes to this event on its browser_conn; the handler must
      # prune the ended session so long-lived browsers don't leak stale entries.
      conn = self()
      state = %Browser{browser_conn: conn, sessions: %{"T1" => "S1", "T2" => "S2"}}

      event =
        {:cdp_event, conn, "Target.detachedFromTarget", %{"sessionId" => "S1", "targetId" => "T1"},
         nil}

      assert {:noreply, %Browser{sessions: %{"T2" => "S2"}}} = Browser.handle_info(event, state)
    end
  end

  describe "browser connection teardown reason" do
    test "a clean ws-closed connection exit stops quietly (a :shutdown reason)" do
      # The Connection stops with {:shutdown, {:ws_closed, _}} when its socket drops
      # cleanly (e.g. Chrome going away). The Browser must propagate that as a
      # :shutdown reason so OTP logs no crash report for expected teardown.
      conn = self()
      state = %Browser{browser_conn: conn}
      reason = {:shutdown, {:ws_closed, :closed}}

      assert {:stop, {:shutdown, {:browser_connection_down, ^reason}}, ^state} =
               Browser.handle_info({:EXIT, conn, reason}, state)
    end

    test "an abnormal connection exit stays loud (a non-shutdown reason)" do
      conn = self()
      state = %Browser{browser_conn: conn}

      assert {:stop, {:browser_connection_down, :boom}, ^state} =
               Browser.handle_info({:EXIT, conn, :boom}, state)
    end
  end

  describe "close_page rejection paths" do
    test "rejects a dedicated handle this browser doesn't own" do
      # The reject branch does no I/O, so it's drivable directly; the match branch
      # (close_target + safe_close) is exercised by the integration suite.
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      state = %Browser{browser_conn: self(), pages: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:close_page, page}, {self(), make_ref()}, state)
    end

    test "rejects a second close of an already-pruned session page" do
      # After Target.detachedFromTarget prunes a session (or a prior close), closing
      # the stale handle again must be refused, not detach an unrelated target.
      page = %Page{browser: self(), conn: self(), target_id: "T1", session_id: "S1"}
      state = %Browser{browser_conn: self(), sessions: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:close_page, page}, {self(), make_ref()}, state)
    end
  end

  describe "child_spec" do
    test "sets a generous :shutdown so terminate/2 can reap Chrome" do
      assert %{shutdown: 10_000} = Browser.child_spec([])
    end
  end

  describe "interception reservation (#30)" do
    test "rejects a :session page (shared-connection ownership problem)" do
      page = %Page{browser: self(), conn: self(), target_id: "T1", session_id: "S1"}
      state = %Browser{}

      assert {:reply, {:error, {:unsupported_transport, :session}}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects a page this browser doesn't own" do
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      state = %Browser{pages: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects when the page is already authenticated (mutual exclusion)" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, auths: %{"T1" => self()}}

      assert {:reply, {:error, {:conflict, :authenticated}}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects a double reservation" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), make_ref()}}}

      assert {:reply, {:error, :already_intercepting}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "records and monitors the caller on success" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}}
      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:reply, :ok, new_state} =
               Browser.handle_call({:reserve_interception, page}, {caller, make_ref()}, state)

      assert {^caller, ref} = new_state.intercepts["T1"]
      assert is_reference(ref)

      Process.exit(caller, :kill)
    end

    test "release demonitors and drops the entry" do
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      ref = Process.monitor(self())
      state = %Browser{intercepts: %{"T1" => {self(), ref}}}

      assert {:reply, :ok, %Browser{intercepts: %{}}} =
               Browser.handle_call({:release_interception, page}, {self(), make_ref()}, state)
    end

    test "an owner :DOWN drops the reservation (the Fetch.disable runs off-process)" do
      # A dead conn makes the fire-and-forget disable Task resolve to :noproc silently;
      # the actual disable is verified end-to-end by the integration suite.
      conn = spawn(fn -> :ok end)
      ref = make_ref()
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), ref}}}

      assert {:noreply, %Browser{intercepts: %{}}} =
               Browser.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    end

    test "an owner :DOWN for an already-closed page drops the reservation without crashing" do
      ref = make_ref()
      state = %Browser{pages: %{}, intercepts: %{"T1" => {self(), ref}}}

      assert {:noreply, %Browser{intercepts: %{}}} =
               Browser.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    end

    test "release of a page with no reservation is an idempotent :ok" do
      page = %Page{browser: self(), conn: self(), target_id: "T_GONE"}
      state = %Browser{intercepts: %{}}

      assert {:reply, :ok, ^state} =
               Browser.handle_call({:release_interception, page}, {self(), make_ref()}, state)
    end

    test "an owner :DOWN for an unknown ref is ignored" do
      state = %Browser{intercepts: %{}}

      assert {:noreply, ^state} =
               Browser.handle_info({:DOWN, make_ref(), :process, self(), :killed}, state)
    end

    test "authenticate is rejected when interception is active (reverse exclusion)" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), make_ref()}}}

      assert {:reply, {:error, {:conflict, :intercepting}}, ^state} =
               Browser.handle_call(
                 {:authenticate, page, [username: "u", password: "p"]},
                 {self(), make_ref()},
                 state
               )
    end
  end

  describe "non-blocking authenticate (#36)" do
    test "{:armed} replies :ok to the parked caller and clears pending_auth" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{pending_auth: %{fetch => {from, make_ref()}}}

      assert {:noreply, %Browser{pending_auth: %{}}} = Browser.handle_info({:armed, fetch}, state)

      {_pid, tag} = from
      assert_receive {^tag, :ok}
    end

    test "{:arm_failed} fails the parked caller and clears its auths + pending_auth" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{fetch => {from, make_ref()}}}

      assert {:noreply, new_state} =
               Browser.handle_info(
                 {:arm_failed, fetch, {:cdp_error, "Fetch.enable", %{}}},
                 state
               )

      assert new_state.pending_auth == %{}
      assert new_state.auths == %{}

      {_pid, tag} = from
      assert_receive {^tag, {:error, {:cdp_error, "Fetch.enable", %{}}}}
    end

    test "a Fetch handler {:EXIT} during arming fails a still-parked caller (fallback)" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{fetch => {from, make_ref()}}}

      assert {:noreply, new_state} = Browser.handle_info({:EXIT, fetch, :boom}, state)

      assert new_state.pending_auth == %{}
      {_pid, tag} = from
      assert_receive {^tag, {:error, :boom}}
    end

    test "{:armed} for an unknown pid is a no-op (late or duplicate signal)" do
      state = %Browser{pending_auth: %{}}
      assert {:noreply, ^state} = Browser.handle_info({:armed, spawn(fn -> :ok end)}, state)
    end

    test "{:arm_failed} for an unknown pid is a no-op" do
      state = %Browser{pending_auth: %{}}

      assert {:noreply, ^state} =
               Browser.handle_info({:arm_failed, spawn(fn -> :ok end), :boom}, state)
    end
  end

  describe "auth caller-departure cleanup (#40)" do
    test "a monitored caller's :DOWN cancels the orphaned handler and drops pending_auth" do
      # The authenticate/4 caller departed (e.g. its 15s call timed out) while the Fetch
      # handler was still arming. Cancel the handler (a gen_cast) and drop its pending_auth
      # entry, but leave auths for the handler's eventual {:EXIT} to clear (two phase).
      test = self()
      fetch = spawn(fn -> receive(do: (msg -> send(test, {:fetch_got, msg}))) end)
      caller = spawn(fn -> :ok end)
      caller_ref = make_ref()
      from = {caller, make_ref()}
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{fetch => {from, caller_ref}}}

      assert {:noreply, new_state} =
               Browser.handle_info({:DOWN, caller_ref, :process, caller, :timeout}, state)

      assert new_state.pending_auth == %{}
      # auths is intentionally retained — the handler's cancel-stop {:EXIT} clears it.
      assert new_state.auths == %{"T1" => fetch}
      assert_receive {:fetch_got, {:"$gen_cast", :cancel}}
    end

    test "the orphaned handler's later {:EXIT} clears its auths entry (re-authenticatable)" do
      # Phase two: after the cancel, the handler stops and its {:EXIT} arrives with no
      # pending_auth entry left — it must still drop auths so a retry isn't stuck on
      # {:error, :already_authenticated}.
      fetch = spawn(fn -> :ok end)
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{}}

      assert {:noreply, %Browser{auths: %{}, pending_auth: %{}}} =
               Browser.handle_info({:EXIT, fetch, :normal}, state)
    end

    test "a :DOWN matching neither an interception owner nor an auth caller is ignored" do
      state = %Browser{intercepts: %{}, pending_auth: %{}}

      assert {:noreply, ^state} =
               Browser.handle_info({:DOWN, make_ref(), :process, self(), :noproc}, state)
    end
  end

  describe "proxy auto-auth cleanup (FakeCDP fault injection)" do
    test "an arm failure during new_page tears down the just-created page and surfaces the error" do
      # Drive the full new_page → reply_proxy_authed_page path against a fake Chrome and
      # make Fetch.enable fail, so the synchronous arm (await_fetch_armed) returns an error
      # and close_failed_auth_page must close the page that was never handed back. A
      # dedicated process plays the fake Chrome (the FakeCDP controller, answering every
      # CDP frame and erroring only Fetch.enable), leaving this process free to run the
      # blocking handle_call in a Task and await its reply.
      test = self()
      fake = spawn_link(fn -> fake_chrome_failing_arm(test) end)
      {:ok, server} = FakeCDP.start(fake)
      {:ok, browser_conn} = Connection.start_link(server.url)

      state = %Browser{
        browser_conn: browser_conn,
        host: "127.0.0.1",
        port: server.port,
        proxy_auth: %{username: "u", password: "p"}
      }

      log =
        capture_log(fn ->
          task =
            Task.async(fn ->
              Browser.handle_call({:new_page, []}, {self(), make_ref()}, state)
            end)

          assert {:reply, {:error, {:cdp_error, "Fetch.enable", _}}, new_state} =
                   Task.await(task, 30_000)

          # The page was opened then torn down: dropped from state, never recorded as
          # authed, and its orphaned Chrome tab actually closed (Target.closeTarget sent).
          assert new_state.pages == %{}
          assert new_state.auths == %{}
          assert_receive :close_target_sent, 1_000
        end)

      assert log =~ "arming failed"

      Connection.close(browser_conn)
    end
  end

  # A fake Chrome for the test above: answer every CDP frame the new_page conversation
  # issues — a targetId for Target.createTarget, an OK for the bootstrap calls (and the
  # teardown Fetch.disable), but an ERROR for Fetch.enable, the fault that makes the
  # proxy-auth arm fail. Tells `test` when it sees Target.closeTarget, so the test can
  # assert the orphaned tab was actually closed. Loops until its linker (the test process)
  # exits, so there's no per-message timeout to race CI load — Task.await is the deadline.
  defp fake_chrome_failing_arm(test) do
    receive do
      {:fake_cdp_recv, fake, %{"id" => id, "method" => "Target.createTarget"}} ->
        FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"targetId":"T1"}}))

      {:fake_cdp_recv, fake, %{"id" => id, "method" => "Fetch.enable"}} ->
        FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}}))

      {:fake_cdp_recv, fake, %{"id" => id, "method" => "Target.closeTarget"}} ->
        send(test, :close_target_sent)
        FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

      {:fake_cdp_recv, fake, %{"id" => id}} ->
        FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

      {:fake_cdp_connected, _fake} ->
        :ok
    end

    fake_chrome_failing_arm(test)
  end

  describe "isolated pages: opening" do
    test "isolated: true creates a context and opens the target in it (:session)" do
      {state, conn} = fake_browser_state()

      assert {:reply, {:ok, %Page{target_id: "T1", session_id: "S1"}}, new_state} =
               new_page_in_task(state, transport: :session, isolated: true)

      assert_receive {:sent, "Target.createBrowserContext", %{"disposeOnDetach" => true}}
      assert_receive {:sent, "Target.createTarget", %{"browserContextId" => "C1"}}
      assert new_state.contexts == %{"T1" => "C1"}
      assert new_state.sessions == %{"T1" => "S1"}
      Connection.close(conn)
    end

    test "isolated: true on :dedicated records the context" do
      {state, conn} = fake_browser_state()

      assert {:reply, {:ok, %Page{target_id: "T1", session_id: nil}}, new_state} =
               new_page_in_task(state, transport: :dedicated, isolated: true)

      assert_receive {:sent, "Target.createTarget", %{"browserContextId" => "C1"}}
      assert new_state.contexts == %{"T1" => "C1"}
      assert Map.has_key?(new_state.pages, "T1")
      Connection.close(conn)
    end

    test "a failed createTarget in a new context disposes the context" do
      {state, conn} = fake_browser_state(%{"Target.createTarget" => :error})

      assert {:reply, {:error, {:cdp_error, "Target.createTarget", _}}, new_state} =
               new_page_in_task(state, transport: :session, isolated: true)

      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      assert new_state.contexts == %{}
      Connection.close(conn)
    end

    test "a failed bootstrap disposes the context, not just the target" do
      {state, conn} = fake_browser_state(%{"Page.enable" => :error})

      assert {:reply, {:error, {:cdp_error, "Page.enable", _}}, new_state} =
               new_page_in_task(state, transport: :session, isolated: true)

      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      refute_received {:sent, "Target.closeTarget", _}
      assert new_state.contexts == %{}
      assert new_state.sessions == %{}
      Connection.close(conn)
    end

    test "isolated: false and no option send no context command" do
      {state, conn} = fake_browser_state()

      assert {:reply, {:ok, _}, s1} = new_page_in_task(state, transport: :session, isolated: false)
      assert {:reply, {:ok, _}, _} = new_page_in_task(s1, transport: :session)

      refute_received {:sent, "Target.createBrowserContext", _}
      assert_received {:sent, "Target.createTarget", params}
      refute Map.has_key?(params, "browserContextId")
      Connection.close(conn)
    end

    test "a non-boolean :isolated raises ArgumentError in the caller" do
      assert_raise ArgumentError, ~r/:isolated/, fn -> Browser.new_page(self(), isolated: :yes) end
    end
  end

  describe "isolated pages: disposing" do
    test "close_page on an isolated session page disposes its context instead of closeTarget" do
      {state, conn} = fake_browser_state()
      state = %{state | sessions: %{"T1" => "S1"}, contexts: %{"T1" => "C1"}}
      page = %Page{browser: self(), conn: conn, target_id: "T1", session_id: "S1"}

      assert {:reply, :ok, new_state} = call_in_task(state, {:close_page, page})

      assert_receive {:sent, "Target.detachFromTarget", %{"sessionId" => "S1"}}
      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      refute_received {:sent, "Target.closeTarget", _}
      assert new_state.contexts == %{}
      assert new_state.sessions == %{}
      Connection.close(conn)
    end

    test "close_page on an isolated dedicated page disposes its context" do
      {state, conn} = fake_browser_state()
      {:ok, page_conn} = Connection.start_link("ws://127.0.0.1:#{state.port}/devtools/page/T1")
      state = %{state | pages: %{"T1" => page_conn}, contexts: %{"T1" => "C1"}}
      page = %Page{browser: self(), conn: page_conn, target_id: "T1"}

      assert {:reply, :ok, new_state} = call_in_task(state, {:close_page, page})

      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      refute_received {:sent, "Target.closeTarget", _}
      assert new_state.contexts == %{}
      assert new_state.pages == %{}
      Connection.close(conn)
    end

    test "a second close of an isolated page is :unknown_page and sends nothing" do
      {state, conn} = fake_browser_state()
      state = %{state | sessions: %{"T1" => "S1"}, contexts: %{"T1" => "C1"}}
      page = %Page{browser: self(), conn: conn, target_id: "T1", session_id: "S1"}

      assert {:reply, :ok, closed} = call_in_task(state, {:close_page, page})
      assert_receive {:sent, "Target.disposeBrowserContext", _}

      assert {:reply, {:error, :unknown_page}, ^closed} = call_in_task(closed, {:close_page, page})
      refute_receive {:sent, "Target.disposeBrowserContext", _}, 200
      Connection.close(conn)
    end

    test "page-conn EXIT disposes the page's context" do
      {state, conn} = fake_browser_state()
      page_conn = spawn(fn -> :ok end)
      state = %{state | pages: %{"T1" => page_conn}, contexts: %{"T1" => "C1"}}

      assert {:noreply, new_state} = info_in_task(state, {:EXIT, page_conn, :boom})

      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      assert new_state.contexts == %{}
      assert new_state.pages == %{}
      Connection.close(conn)
    end

    test "Target.detachedFromTarget disposes the session page's context" do
      {state, conn} = fake_browser_state()
      state = %{state | sessions: %{"T1" => "S1"}, contexts: %{"T1" => "C1"}}

      event =
        {:cdp_event, conn, "Target.detachedFromTarget", %{"sessionId" => "S1", "targetId" => "T1"},
         nil}

      assert {:noreply, new_state} = info_in_task(state, event)

      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
      assert new_state.contexts == %{}
      Connection.close(conn)
    end

    test "a failed proxy-auth arm disposes the context" do
      {state, conn} = fake_browser_state(%{"Fetch.enable" => :error})
      state = %{state | proxy_auth: %{username: "u", password: "p"}}

      capture_log(fn ->
        assert {:reply, {:error, {:cdp_error, "Fetch.enable", _}}, new_state} =
                 new_page_in_task(state, transport: :dedicated, isolated: true)

        assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}, 1_000
        assert new_state.contexts == %{}
        assert new_state.pages == %{}
      end)

      Connection.close(conn)
    end

    test "terminate/2 on a connected browser disposes its contexts" do
      {state, _conn} = fake_browser_state()
      state = %{state | connected: true, sessions: %{"T1" => "S1"}, contexts: %{"T1" => "C1"}}

      assert :ok = Task.await(Task.async(fn -> Browser.terminate(:normal, state) end), 30_000)
      assert_receive {:sent, "Target.disposeBrowserContext", %{"browserContextId" => "C1"}}
    end
  end

  describe "isolated pages: telemetry" do
    test "page start/stop metadata carries isolated" do
      handler = "isolated-telemetry-#{inspect(self())}"
      test = self()

      :telemetry.attach_many(
        handler,
        [[:cdp_ex, :page, :start], [:cdp_ex, :page, :stop]],
        &__MODULE__.forward_telemetry/4,
        test
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {state, conn} = fake_browser_state()

      assert {:reply, {:ok, page}, opened} =
               new_page_in_task(state, transport: :session, isolated: true)

      assert_receive {:telemetry, [:cdp_ex, :page, :start], %{isolated: true}}
      assert {:reply, :ok, _} = call_in_task(opened, {:close_page, page})
      assert_receive {:telemetry, [:cdp_ex, :page, :stop], %{isolated: true}}

      assert {:reply, {:ok, _}, _} = new_page_in_task(state, transport: :session)
      assert_receive {:telemetry, [:cdp_ex, :page, :start], %{isolated: false}}
      Connection.close(conn)
    end
  end

  def forward_telemetry(event, _measurements, meta, test), do: send(test, {:telemetry, event, meta})

  defp call_in_task(state, request) do
    fn -> Browser.handle_call(request, {self(), make_ref()}, state) end
    |> Task.async()
    |> Task.await(30_000)
  end

  defp info_in_task(state, msg) do
    fn -> Browser.handle_info(msg, state) end |> Task.async() |> Task.await(30_000)
  end

  # A Browser state whose browser_conn talks to a fake Chrome (see fake_chrome/2).
  defp fake_browser_state(overrides \\ %{}) do
    test = self()
    fake = spawn_link(fn -> fake_chrome(test, overrides) end)
    {:ok, server} = FakeCDP.start(fake)
    {:ok, conn} = Connection.start_link(server.url)
    {%Browser{browser_conn: conn, host: "127.0.0.1", port: server.port}, conn}
  end

  # Runs the blocking new_page handle_call off the test process, which receives the
  # fake Chrome's {:sent, method, params} reports.
  defp new_page_in_task(state, opts) do
    fn -> Browser.handle_call({:new_page, opts}, {self(), make_ref()}, state) end
    |> Task.async()
    |> Task.await(30_000)
  end

  # A fake Chrome that answers every frame (on the browser and any page connection),
  # reports each as {:sent, method, params} to `test`, and errors the methods named in
  # `overrides` (method => :error).
  defp fake_chrome(test, overrides) do
    receive do
      {:fake_cdp_recv, fake, %{"id" => id, "method" => method} = frame} ->
        send(test, {:sent, method, Map.get(frame, "params", %{})})

        reply =
          case {Map.get(overrides, method), method} do
            {:error, _} ->
              ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}})

            {_, "Target.createBrowserContext"} ->
              ~s({"id":#{id},"result":{"browserContextId":"C1"}})

            {_, "Target.createTarget"} ->
              ~s({"id":#{id},"result":{"targetId":"T1"}})

            {_, "Target.attachToTarget"} ->
              ~s({"id":#{id},"result":{"sessionId":"S1"}})

            _ ->
              ~s({"id":#{id},"result":{}})
          end

        FakeCDP.send_text(fake, reply)

      {:fake_cdp_connected, _fake} ->
        :ok
    end

    fake_chrome(test, overrides)
  end
end
