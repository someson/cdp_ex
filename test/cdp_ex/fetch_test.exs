defmodule CDPEx.FetchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Fetch

  # Credentials travel as a closure, so no crash report or :sys.get_status/1 prints them.
  @auto_attach %{
    "autoAttach" => true,
    "waitForDebuggerOnStart" => true,
    "flatten" => true,
    "filter" => [%{"type" => "iframe"}, %{"type" => "worker"}]
  }
  @console ["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]

  defp creds, do: fn -> {"u", "p"} end
  defp auth, do: %{credentials: creds(), source: :any}

  describe "auth_decision/5" do
    test "provides credentials for a matching challenge and records the attempt" do
      {response, attempts} = Fetch.auth_decision(:any, %{}, "R1", %{"source" => "Server"}, creds())

      assert response == %{
               "response" => "ProvideCredentials",
               "username" => "u",
               "password" => "p"
             }

      assert attempts == %{"R1" => 1}
    end

    test "cancels on the second challenge for the same request (rejected credentials)" do
      {response, attempts} =
        Fetch.auth_decision(:any, %{"R1" => 1}, "R1", %{"source" => "Server"}, creds())

      assert response == %{"response" => "CancelAuth"}
      refute Map.has_key?(attempts, "R1")
    end

    test "the :proxy filter answers only Proxy challenges" do
      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Server"}, creds())

      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Proxy"}, creds())
    end

    test "the :server filter answers only Server challenges" do
      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Server"}, creds())

      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Proxy"}, creds())
    end

    test "caps the attempts map so answered-but-unpruned challenges can't grow it unbounded" do
      # Only the rejection path deletes; a successful answer leaves its entry. At the
      # cap a fresh challenge resets the map rather than growing it without bound.
      full = Map.new(1..1024, &{"R#{&1}", 1})
      assert map_size(full) == 1024

      assert {%{"response" => "ProvideCredentials"}, %{"NEW" => 1}} =
               Fetch.auth_decision(:any, full, "NEW", %{"source" => "Server"}, creds())
    end
  end

  describe "enable_params/3" do
    @img_req %{"resourceType" => "Image", "requestStage" => "Request"}

    test "auth only pauses everything and handles auth" do
      assert Fetch.enable_params(%{}, nil, nil) == %{"handleAuthRequests" => true}
    end

    test "interception only sends the caller's patterns as they are" do
      patterns = [%{"urlPattern" => "*.png", "requestStage" => "Response"}]
      assert Fetch.enable_params(nil, patterns, nil) == %{"patterns" => patterns}
    end

    test "both pause every request and keep the caller's Response-stage patterns" do
      patterns = [
        %{"resourceType" => "Image"},
        %{"urlPattern" => "*/api/*", "requestStage" => "Response"}
      ]

      assert Fetch.enable_params(%{}, patterns, nil) == %{
               "patterns" => [
                 %{"urlPattern" => "*"},
                 %{"urlPattern" => "*/api/*", "requestStage" => "Response"}
               ],
               "handleAuthRequests" => true
             }
    end

    test "block only pauses just the blocked types at the Request stage" do
      assert Fetch.enable_params(nil, nil, ["Image", "Font"]) == %{
               "patterns" => [
                 @img_req,
                 %{"resourceType" => "Font", "requestStage" => "Request"}
               ]
             }
    end

    test "block and interception send the blocked types first, then the caller's" do
      assert Fetch.enable_params(nil, [%{"urlPattern" => "*.css"}], ["Image"]) == %{
               "patterns" => [@img_req, %{"urlPattern" => "*.css"}]
             }
    end

    test "auth with block is the auth shape" do
      assert Fetch.enable_params(%{}, nil, ["Image"]) == %{"handleAuthRequests" => true}

      response = [%{"urlPattern" => "*/api/*", "requestStage" => "Response"}]

      assert Fetch.enable_params(%{}, response, ["Image"]) ==
               Fetch.enable_params(%{}, response, nil)
    end

    test "nothing on means disabled" do
      assert Fetch.enable_params(nil, nil, nil) == nil
    end
  end

  describe "resource_types/1" do
    test "each block atom maps to its CDP resource type" do
      table = [
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
      ]

      for {atom, type} <- table, do: assert(Fetch.resource_types([atom]) == {:ok, [type]})
      assert Fetch.resource_types(Keyword.keys(table)) == {:ok, Keyword.values(table)}
    end

    test "duplicates collapse" do
      assert Fetch.resource_types([:image, :font, :image]) == {:ok, ["Image", "Font"]}
    end

    test "an empty list blocks nothing" do
      assert Fetch.resource_types([]) == {:ok, []}
    end

    test "documents, websockets, unknown atoms and non-lists are invalid" do
      for bad <- [[:document], [:websocket], [:nope], ["Image"], [:image, "Font"], :image, nil] do
        assert Fetch.resource_types(bad) == {:error, {:invalid_args, {:block, bad}}}
      end
    end
  end

  describe "compile_matchers/1 + matches?/2" do
    defp paused(url, type \\ "Document"),
      do: %{"requestId" => "R", "request" => %{"url" => url}, "resourceType" => type}

    defp hits?(patterns, params), do: Fetch.matches?(Fetch.compile_matchers(patterns), params)

    test "* matches any run of characters, including none and slashes" do
      assert hits?([%{"urlPattern" => "*"}], paused("https://a.test/x"))
      assert hits?([%{"urlPattern" => "https://a.test/*"}], paused("https://a.test/"))
      assert hits?([%{"urlPattern" => "*.png"}], paused("https://a.test/i/x.png"))
      refute hits?([%{"urlPattern" => "*.png"}], paused("https://a.test/x.png?v=1"))
    end

    test "? matches exactly one character" do
      assert hits?([%{"urlPattern" => "https://a.test/?"}], paused("https://a.test/x"))
      refute hits?([%{"urlPattern" => "https://a.test/?"}], paused("https://a.test/"))
      refute hits?([%{"urlPattern" => "https://a.test/?"}], paused("https://a.test/xy"))
    end

    test "a backslash escapes a wildcard, and regex metacharacters are literal" do
      assert hits?([%{"urlPattern" => "https://a.test/\\*"}], paused("https://a.test/*"))
      refute hits?([%{"urlPattern" => "https://a.test/\\*"}], paused("https://a.test/x"))
      assert hits?([%{"urlPattern" => "*?q=(1)"}], paused("https://a.test/?q=(1)"))
      refute hits?([%{"urlPattern" => "https://a.test/x.png"}], paused("https://a.test/xApng"))
    end

    test "a missing urlPattern matches every URL" do
      assert hits?([%{"resourceType" => "Image"}], paused("https://a.test/x", "Image"))
    end

    test "resourceType must match when given" do
      assert hits?([%{"resourceType" => "Image"}], paused("https://a.test/x.png", "Image"))
      refute hits?([%{"resourceType" => "Image"}], paused("https://a.test/x.png", "Font"))
    end

    test "any matching pattern is enough" do
      patterns = [%{"resourceType" => "Image"}, %{"urlPattern" => "*.woff2"}]
      assert hits?(patterns, paused("https://a.test/f.woff2", "Font"))
      refute hits?(patterns, paused("https://a.test/", "Document"))
    end

    test "Response-stage patterns don't match Request-stage pauses" do
      refute hits?([%{"urlPattern" => "*", "requestStage" => "Response"}], paused("https://a/"))
    end
  end

  describe "decide/2" do
    defp with_modes(auth, patterns, block \\ nil) do
      intercept =
        patterns && %{owner: self(), patterns: patterns, matchers: Fetch.compile_matchers(patterns)}

      %Fetch{auth: auth, intercept: intercept, block: block}
    end

    test "nothing is forwarded without interception" do
      assert Fetch.decide(with_modes(%{}, nil), paused("https://a/")) == :continue
    end

    test "with interception alone, the owner gets the pauses matching its patterns" do
      state = with_modes(nil, [%{"resourceType" => "Image"}])
      assert Fetch.decide(state, paused("https://a/x.png", "Image")) == :forward
    end

    test "with interception alone, a pause outside the owner's patterns continues" do
      # A pause Chrome made under the previous enable (an image while the block set
      # shrank to nothing) arrives after the state changed: it isn't the owner's.
      state = with_modes(nil, [%{"resourceType" => "Stylesheet"}])
      assert Fetch.decide(state, paused("https://a/x.png", "Image")) == :continue
    end

    test "with auth only matching Request-stage pauses and every Response-stage pause go" do
      state = with_modes(%{}, [%{"resourceType" => "Image"}])
      assert Fetch.decide(state, paused("https://a/x.png", "Image")) == :forward
      assert Fetch.decide(state, paused("https://a/", "Document")) == :continue

      response = Map.put(paused("https://a/", "Document"), "responseStatusCode", 200)
      assert Fetch.decide(state, response) == :forward

      failed = Map.put(paused("https://a/", "Document"), "responseErrorReason", "Failed")
      assert Fetch.decide(state, failed) == :forward
    end

    test "a blocked type at the Request stage is :block, whatever the other modes" do
      for auth <- [nil, %{}], patterns <- [nil, [%{"urlPattern" => "*"}]] do
        state = with_modes(auth, patterns, ["Image"])
        assert Fetch.decide(state, paused("https://a/x.png", "Image")) == :block
      end
    end

    test "Response-stage pauses are never blocked" do
      state =
        with_modes(nil, [%{"resourceType" => "Image", "requestStage" => "Response"}], ["Image"])

      response = Map.put(paused("https://a/x.png", "Image"), "responseStatusCode", 200)
      assert Fetch.decide(state, response) == :forward
    end

    test "with block on and auth off, Request-stage pauses are matched against the owner's patterns" do
      state = with_modes(nil, [%{"urlPattern" => "*.css"}], ["Image"])
      assert Fetch.decide(state, paused("https://a/x.css", "Stylesheet")) == :forward
      assert Fetch.decide(state, paused("https://a/", "Document")) == :continue
    end

    test "block alone continues what it doesn't block" do
      state = with_modes(nil, nil, ["Image"])
      assert Fetch.decide(state, paused("https://a/", "Document")) == :continue
    end
  end

  describe "a dead connection" do
    test "stops the owner at once; the Browser fails any caller parked on it" do
      Process.flag(:trap_exit, true)

      conn = spawn(fn -> :ok end)
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 1_000

      assert {:ok, pid} = Fetch.start_link(conn: conn, browser: self())
      assert_receive {:EXIT, ^pid, :normal}, 1_000
    end
  end

  describe "the owner on FakeCDP" do
    setup do
      {:ok, server} = FakeCDP.start()
      {:ok, conn} = Connection.start_link(server.url)
      assert_receive {:fake_cdp_connected, fake}, 2_000

      on_exit(fn ->
        try do
          if Process.alive?(conn), do: Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      %{conn: conn, fake: fake}
    end

    test "auth enables Fetch with handleAuthRequests, replies :ok, rejects a second auth", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)

      tag = make_ref()
      Fetch.request(pid, tag, {:auth, auth()})
      assert expect_call(fake, "Fetch.enable") == %{"handleAuthRequests" => true}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      tag2 = make_ref()
      Fetch.request(pid, tag2, {:auth, auth()})
      assert_receive {:fetch_reply, ^pid, ^tag2, {:error, :already_authenticated}}, 2_000
    end

    test "a failed enable leaves the mode off, so a retry can arm it", %{conn: conn, fake: fake} do
      pid = start_owner(conn)

      log =
        capture_log(fn ->
          tag = make_ref()
          Fetch.request(pid, tag, {:auth, auth()})
          expect_call(fake, "Fetch.enable", :error)

          assert_receive {:fetch_reply, ^pid, ^tag, {:error, {:cdp_error, "Fetch.enable", _}}},
                         2_000
        end)

      assert log =~ "arming failed"

      tag = make_ref()
      Fetch.request(pid, tag, {:auth, auth()})
      expect_call(fake, "Fetch.enable")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "interception alone sends the caller's patterns and forwards its pauses", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      patterns = [%{"resourceType" => "Image"}]

      tag = make_ref()
      Fetch.request(pid, tag, {:intercept, self(), patterns, 5_000})
      assert expect_call(fake, "Fetch.enable") == %{"patterns" => patterns}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      pause(fake, "r1", "https://a.test/x.png", "Image")
      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => "r1"}, nil}, 2_000
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.continueRequest"}}, 100

      tag = make_ref()
      Fetch.request(pid, tag, {:intercept, self(), patterns, 5_000})
      assert_receive {:fetch_reply, ^pid, ^tag, {:error, :already_intercepting}}, 2_000
    end

    test "with auth and interception, the owner gets only its pauses; the rest continue", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})

      tag = make_ref()
      Fetch.request(pid, tag, {:intercept, self(), [%{"resourceType" => "Image"}], 5_000})

      assert expect_call(fake, "Fetch.enable") == %{
               "patterns" => [%{"urlPattern" => "*"}],
               "handleAuthRequests" => true
             }

      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      pause(fake, "img", "https://a.test/x.png", "Image")
      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => "img"}, nil}, 2_000

      pause(fake, "doc", "https://a.test/", "Document")
      assert expect_call(fake, "Fetch.continueRequest") == %{"requestId" => "doc"}
      refute_received {:cdp_event, _, "Fetch.requestPaused", %{"requestId" => "doc"}, _}

      # The proxy challenge is still answered.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Fetch.authRequired","params":{"requestId":"doc","authChallenge":{"source":"Proxy"}}})
      )

      assert %{"authChallengeResponse" => %{"response" => "ProvideCredentials"}} =
               expect_call(fake, "Fetch.continueWithAuth")
    end

    test "interception can come first, then auth", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:intercept, self(), [%{"urlPattern" => "*.png"}], 5_000})

      tag = make_ref()
      Fetch.request(pid, tag, {:auth, auth()})

      assert %{"handleAuthRequests" => true, "patterns" => [%{"urlPattern" => "*"}]} =
               expect_call(fake, "Fetch.enable")

      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "an owner that dies with auth on: its pauses are let through, auth re-armed alone", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})
      owner = relay_owner()
      arm(pid, fake, {:intercept, owner, [%{"resourceType" => "Image"}], 5_000})

      pause(fake, "img", "https://a.test/x.png", "Image")
      assert_receive {:owner_got, {:cdp_event, _, "Fetch.requestPaused", _, _}}, 2_000

      Process.exit(owner, :kill)

      assert expect_call(fake, "Fetch.continueRequest") == %{"requestId" => "img"}
      assert expect_call(fake, "Fetch.enable") == %{"handleAuthRequests" => true}

      # Everything is continued by the owner again.
      pause(fake, "img2", "https://a.test/y.png", "Image")
      assert expect_call(fake, "Fetch.continueRequest") == %{"requestId" => "img2"}
    end

    test "an owner that dies without auth disables Fetch", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      owner = relay_owner()
      arm(pid, fake, {:intercept, owner, [%{"urlPattern" => "*"}], 5_000})

      Process.exit(owner, :kill)
      expect_call(fake, "Fetch.disable")
      assert Process.alive?(pid)
    end

    test "release keeps auth working and replies the CDP result", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})
      arm(pid, fake, {:intercept, self(), [%{"resourceType" => "Image"}], 5_000})

      tag = make_ref()
      Fetch.request(pid, tag, {:release_intercept, 5_000})
      assert expect_call(fake, "Fetch.enable") == %{"handleAuthRequests" => true}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      # Released twice is fine.
      tag = make_ref()
      Fetch.request(pid, tag, {:release_intercept, 5_000})
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "Fetch.authRequired is left alone while auth is off", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:intercept, self(), [%{"urlPattern" => "*"}], 5_000})

      FakeCDP.send_text(
        fake,
        ~s({"method":"Fetch.authRequired","params":{"requestId":"r","authChallenge":{"source":"Proxy"}}})
      )

      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.continueWithAuth"}}, 200
      assert Process.alive?(pid)
    end

    test "drop_auth drops only the auth it names", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      tag = make_ref()
      Fetch.request(pid, tag, {:auth, auth()})
      expect_call(fake, "Fetch.enable")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      Fetch.request(pid, make_ref(), {:drop_auth, make_ref()})
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.disable"}}, 200

      Fetch.request(pid, make_ref(), {:drop_auth, tag})
      expect_call(fake, "Fetch.disable")
    end

    test "stop/1 ends the owner without touching the page's Fetch domain", %{
      conn: conn,
      fake: fake
    } do
      Process.flag(:trap_exit, true)
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})

      :ok = Fetch.stop(pid)
      assert_receive {:EXIT, ^pid, :normal}, 2_000
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.disable"}}, 100
    end

    test "a :session owner answers only its session and stops on its session's detach", %{
      conn: conn,
      fake: fake
    } do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Fetch.start_link(conn: conn, session_id: "S1", browser: self())
      arm(pid, fake, {:auth, auth()})

      # Another session's pause isn't ours to continue.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Fetch.requestPaused","sessionId":"S2","params":{"requestId":"r2"}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Fetch.requestPaused","sessionId":"S1","params":{"requestId":"r1"}})
      )

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => cid, "method" => "Fetch.continueRequest", "sessionId" => "S1"} =
                        continue},
                     2_000

      assert continue["params"]["requestId"] == "r1"
      FakeCDP.send_text(fake, ~s({"id":#{cid},"result":{}}))

      # Another session's detach leaves it running; its own stops it.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Target.detachedFromTarget","params":{"sessionId":"S2","targetId":"T2"}})
      )

      refute_receive {:EXIT, ^pid, _}, 200

      FakeCDP.send_text(
        fake,
        ~s({"method":"Target.detachedFromTarget","params":{"sessionId":"S1","targetId":"T1"}})
      )

      assert_receive {:EXIT, ^pid, :normal}, 2_000
      refute_received {:fake_cdp_recv, ^fake, %{"params" => %{"requestId" => "r2"}}}
    end

    test "block alone enables the blocked types and fails their pauses with BlockedByClient", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)

      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image"], 5_000})

      assert expect_call(fake, "Fetch.enable") ==
               Fetch.enable_params(nil, nil, ["Image"])

      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      pause(fake, "img", "https://a.test/x.png", "Image")

      assert expect_call(fake, "Fetch.failRequest") == %{
               "requestId" => "img",
               "errorReason" => "BlockedByClient"
             }

      refute_received {:cdp_event, _, "Fetch.requestPaused", _, _}
    end

    test "block [] disables Fetch when it was the only mode", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      tag = make_ref()
      Fetch.request(pid, tag, {:block, [], 5_000})
      expect_call(fake, "Fetch.disable")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "with block and interception, a blocked type is failed, never forwarded", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:intercept, self(), [%{"urlPattern" => "*"}], 5_000})
      arm(pid, fake, {:block, ["Image"], 5_000})

      pause(fake, "img", "https://a.test/x.png", "Image")
      assert %{"requestId" => "img"} = expect_call(fake, "Fetch.failRequest")
      refute_received {:cdp_event, _, "Fetch.requestPaused", %{"requestId" => "img"}, _}

      pause(fake, "doc", "https://a.test/", "Document")
      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => "doc"}, nil}, 2_000
    end

    test "with auth and block, blocked types fail and the rest continue", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})

      # Auth already pauses everything, so block changes no enable param: no CDP call.
      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image"], 5_000})
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
      refute_received {:fake_cdp_recv, ^fake, %{"method" => "Fetch.enable"}}

      pause(fake, "img", "https://a.test/x.png", "Image")
      assert %{"requestId" => "img"} = expect_call(fake, "Fetch.failRequest")

      pause(fake, "doc", "https://a.test/", "Document")
      assert expect_call(fake, "Fetch.continueRequest") == %{"requestId" => "doc"}
    end

    test "an owner that dies with block on: its pauses are let through, block re-armed alone", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      owner = relay_owner()
      arm(pid, fake, {:intercept, owner, [%{"urlPattern" => "*.css"}], 5_000})
      arm(pid, fake, {:block, ["Image"], 5_000})

      pause(fake, "css", "https://a.test/x.css", "Stylesheet")
      assert_receive {:owner_got, {:cdp_event, _, "Fetch.requestPaused", _, _}}, 2_000

      Process.exit(owner, :kill)

      assert expect_call(fake, "Fetch.continueRequest") == %{"requestId" => "css"}
      assert expect_call(fake, "Fetch.enable") == Fetch.enable_params(nil, nil, ["Image"])
    end

    test "a mode change that leaves the enable params as they are sends no Fetch.enable", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image"], 5_000})
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.enable"}}, 100

      # A real change still re-enables.
      arm(pid, fake, {:block, ["Image", "Font"], 5_000})
    end

    test "terminate disables Fetch when only block is on", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      stopper = Task.async(fn -> GenServer.stop(pid) end)
      expect_call(fake, "Fetch.disable")
      Task.await(stopper)
    end

    test "its status shows no proxy credentials", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, %{credentials: fn -> {"puser-x1", "s3cr3t-pw"} end, source: :proxy}})

      status = inspect(:sys.get_status(pid), limit: :infinity)
      refute status =~ "s3cr3t-pw"
      refute status =~ "puser-x1"
    end

    test "a crash report carries no proxy credentials", %{conn: conn, fake: fake} do
      Process.flag(:trap_exit, true)
      pid = start_owner(conn)
      arm(pid, fake, {:auth, %{credentials: fn -> {"puser-x1", "s3cr3t-pw"} end, source: :proxy}})

      log =
        capture_log(fn ->
          # An unknown request crashes the owner with its state in the reason.
          send(pid, {:fetch_request, make_ref(), {:bogus, :request}})
          # terminate/2 still disables the page's Fetch domain.
          expect_call(fake, "Fetch.disable")
          assert_receive {:EXIT, ^pid, {:function_clause, _}}, 2_000
          Process.sleep(200)
        end)

      assert log =~ "CDPEx.Fetch"
      refute log =~ "s3cr3t-pw"
      refute log =~ "puser-x1"
    end
  end

  describe "cross-site iframes on FakeCDP" do
    setup do
      {:ok, server} = FakeCDP.start()
      {:ok, conn} = Connection.start_link(server.url)
      assert_receive {:fake_cdp_connected, fake}, 2_000

      on_exit(fn ->
        try do
          if Process.alive?(conn), do: Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      %{conn: conn, fake: fake}
    end

    test "arming turns on iframe auto-attach on the page's session before the first enable", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image"], 5_000})

      assert expect_call_on(fake, "Target.setAutoAttach", nil) == @auto_attach
      expect_call_on(fake, "Fetch.enable", nil)
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "an attached iframe is filtered, auto-attached and resumed on its own session", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      attach(fake, "C1")
      assert expect_iframe_armed(fake, "C1") == Fetch.enable_params(nil, nil, ["Image"])

      pause_on(fake, "C1", "img", "https://b.test/x.png", "Image")

      assert expect_call_on(fake, "Fetch.failRequest", "C1") == %{
               "requestId" => "img",
               "errorReason" => "BlockedByClient"
             }
    end

    test "an owner that stops with an attach still queued resumes that iframe", %{
      conn: conn,
      fake: fake
    } do
      Process.flag(:trap_exit, true)
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      # The attach lands in the mailbox but is never handled: the owner stops first,
      # as a crash in an earlier message would. Nobody else knows the iframe's session.
      :ok = :sys.suspend(pid)
      attach(fake, "C1")

      assert eventually(fn ->
               match?({:message_queue_len, 1}, Process.info(pid, :message_queue_len))
             end)

      stopper = spawn(fn -> :sys.terminate(pid, {:shutdown, :crashed}) end)

      expect_call_on(fake, "Fetch.disable", nil)
      expect_call_on(fake, "Runtime.runIfWaitingForDebugger", "C1")
      ref = Process.monitor(stopper)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "an iframe is resumed even when its enable fails", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      log =
        capture_log(fn ->
          attach(fake, "C1")
          expect_call_on(fake, "Fetch.enable", "C1", :error)
          expect_call_on(fake, "Runtime.runIfWaitingForDebugger", "C1")
        end)

      assert log =~ "iframe"
    end

    test "a dedicated worker, of the page or of an iframe, is only resumed", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      for {worker, parent} <- [{"W1", nil}, {"W2", "C1"}] do
        attach(fake, worker, parent, "worker")

        assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "sessionId" => ^worker} = frame},
                       2_000

        assert frame["method"] == "Runtime.runIfWaitingForDebugger"
        answer(fake, id, :ok)
      end

      # Not tracked as a child: a mode change reaches the page and the iframe only.
      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image", "Font"], 5_000})
      expect_call_on(fake, "Fetch.enable", nil)
      expect_call_on(fake, "Fetch.enable", "C1")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
      refute_received {:fake_cdp_recv, ^fake, %{"sessionId" => "W" <> _}}
    end

    test "an attach while every mode is off is resumed, unfiltered", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      tag = make_ref()
      Fetch.request(pid, tag, {:block, [], 5_000})
      assert expect_call_on(fake, "Target.setAutoAttach", nil)["autoAttach"] == false
      expect_call_on(fake, "Fetch.disable", nil)
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      attach(fake, "C1")
      expect_call_on(fake, "Runtime.runIfWaitingForDebugger", "C1")
      refute_received {:fake_cdp_recv, ^fake, %{"method" => "Fetch.enable"}}
    end

    test "a mode change reaches every iframe", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image", "Font"], 5_000})
      expect_call_on(fake, "Fetch.enable", nil)

      assert expect_call_on(fake, "Fetch.enable", "C1") ==
               Fetch.enable_params(nil, nil, ["Image", "Font"])

      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "the last mode off disables every iframe and turns auto-attach off", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      tag = make_ref()
      Fetch.request(pid, tag, {:block, [], 5_000})
      expect_call_on(fake, "Fetch.disable", "C1")
      assert expect_call_on(fake, "Target.setAutoAttach", nil)["autoAttach"] == false
      expect_call_on(fake, "Fetch.disable", nil)
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "an iframe's pauses never reach the interception owner", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:intercept, self(), [%{"urlPattern" => "*"}], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      pause_on(fake, "C1", "doc", "https://b.test/", "Document")
      assert expect_call_on(fake, "Fetch.continueRequest", "C1") == %{"requestId" => "doc"}
      refute_received {:cdp_event, _, "Fetch.requestPaused", _, _}
    end

    test "a login challenge on an iframe's session is answered there", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, auth()})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      event(
        fake,
        "Fetch.authRequired",
        %{"requestId" => "r", "authChallenge" => %{"source" => "Proxy"}},
        "C1"
      )

      assert %{"authChallengeResponse" => %{"response" => "ProvideCredentials"}} =
               expect_call_on(fake, "Fetch.continueWithAuth", "C1")
    end

    test "a nested iframe is armed from its parent iframe's session", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      attach(fake, "C2", "C1")
      expect_iframe_armed(fake, "C2")
    end

    test "a detached iframe is forgotten", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      event(fake, "Target.detachedFromTarget", %{"sessionId" => "C1", "targetId" => "T-C1"})
      pause_on(fake, "C1", "img", "https://b.test/x.png", "Image")
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Fetch.failRequest"}}, 200
      assert Process.alive?(pid)
    end
  end

  describe "iframe console on FakeCDP" do
    setup do
      {:ok, server} = FakeCDP.start()
      {:ok, conn} = Connection.start_link(server.url)
      assert_receive {:fake_cdp_connected, fake}, 2_000

      on_exit(fn ->
        try do
          if Process.alive?(conn), do: Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      %{conn: conn, fake: fake}
    end

    test "observing turns on iframe auto-attach with no Fetch mode", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      tag = make_ref()
      Fetch.request(pid, tag, {:observe_console, self(), @console, 5_000})

      assert expect_strict(fake, "Target.setAutoAttach", nil) == @auto_attach
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
      refute_received {:fake_cdp_recv, ^fake, %{"method" => "Fetch.enable"}}
    end

    test "a second observer sends nothing to Chrome", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      observe(pid, fake, self())

      tag = make_ref()
      Fetch.request(pid, tag, {:observe_console, relay_owner(), @console, 5_000})
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
      refute_received {:fake_cdp_recv, ^fake, _}
    end

    test "an attached iframe gets Runtime, auto-attach and a resume, but no Fetch", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      observe(pid, fake, self())

      attach(fake, "C1")
      expect_console_armed(fake, "C1")
      refute_received {:fake_cdp_recv, ^fake, %{"method" => "Fetch.enable"}}
    end

    test "a :session owner passes an iframe's console events to every observer it asked for",
         %{conn: conn, fake: fake} do
      pid = start_owner(conn, "S")
      other = relay_owner()
      observe(pid, fake, self())
      observe(pid, fake, other, ["Runtime.exceptionThrown"])
      attach(fake, "C1", "S")
      expect_console_armed(fake, "C1")

      event(fake, "Runtime.consoleAPICalled", %{"type" => "log"}, "C1")
      event(fake, "Runtime.exceptionThrown", %{"exceptionDetails" => %{}}, "C1")

      assert_receive {:cdp_event, ^conn, "Runtime.consoleAPICalled", %{"type" => "log"}, "C1"},
                     2_000

      assert_receive {:cdp_event, ^conn, "Runtime.exceptionThrown", _, "C1"}, 2_000
      assert_receive {:owner_got, {:cdp_event, ^conn, "Runtime.exceptionThrown", _, "C1"}}, 2_000
      refute_receive {:owner_got, {:cdp_event, _, "Runtime.consoleAPICalled", _, _}}, 200
    end

    test "a :session owner doesn't pass on the page's own console events", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn, "S")
      observe(pid, fake, self())

      event(fake, "Runtime.consoleAPICalled", %{"type" => "log"}, "S")
      refute_receive {:cdp_event, _, "Runtime.consoleAPICalled", _, _}, 200
    end

    test "a :dedicated owner passes nothing on: the observer gets it from the connection", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      observer = relay_owner()
      observe(pid, fake, observer)
      attach(fake, "C1")
      expect_console_armed(fake, "C1")

      event(fake, "Runtime.consoleAPICalled", %{"type" => "log"}, "C1")
      refute_receive {:owner_got, _}, 200
    end

    test "iframes attached under a Fetch mode get Runtime when observing starts", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      attach(fake, "C1")
      expect_iframe_armed(fake, "C1")

      tag = make_ref()
      Fetch.request(pid, tag, {:observe_console, self(), @console, 5_000})
      expect_call_on(fake, "Runtime.enable", "C1")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "with an observer, the last Fetch mode off keeps auto-attach on", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      observe(pid, fake, self())

      tag = make_ref()
      Fetch.request(pid, tag, {:block, [], 5_000})
      expect_strict(fake, "Fetch.disable", nil)
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      attach(fake, "C1")
      expect_console_armed(fake, "C1")
    end

    test "the last observer gone with no Fetch mode turns auto-attach off", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      observe(pid, fake, self())

      Fetch.request(pid, make_ref(), {:unobserve_console, self()})
      assert expect_strict(fake, "Target.setAutoAttach", nil)["autoAttach"] == false
    end

    test "an observer that dies is dropped, and auto-attach goes off", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      observer = relay_owner()
      observe(pid, fake, observer)

      Process.exit(observer, :kill)
      assert expect_strict(fake, "Target.setAutoAttach", nil)["autoAttach"] == false
      assert Process.alive?(pid)
    end

    test "unobserving keeps auto-attach on while a Fetch mode needs it", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})
      observe(pid, fake, self())

      Fetch.request(pid, make_ref(), {:unobserve_console, self()})
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Target.setAutoAttach"}}, 200
    end

    test "terminate turns auto-attach off with observers left", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      observe(pid, fake, self())

      GenServer.stop(pid)
      assert expect_strict(fake, "Target.setAutoAttach", nil)["autoAttach"] == false
    end
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp start_owner(conn, session_id \\ nil) do
    {:ok, pid} = Fetch.start_link(conn: conn, browser: self(), session_id: session_id)
    pid
  end

  # Send `request`, answer its Fetch.enable, and wait for the :ok reply.
  defp arm(pid, fake, request) do
    tag = make_ref()
    Fetch.request(pid, tag, request)
    expect_call(fake, "Fetch.enable")
    assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
  end

  # Wait for a CDP call to `method`, answer it (OK or an error), and return its params.
  # Wait for a CDP call to `method` (on any session), answer it (OK or an error), and
  # return its params. A Target.setAutoAttach the owner sends on the way (it turns
  # iframe auto-attach on before the first enable and off before a disable) is
  # answered OK, unless it is the call waited for.
  defp expect_call(fake, method, outcome \\ :ok) do
    receive do
      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => ^method} = frame} ->
        answer(fake, id, outcome)
        frame["params"] || %{}

      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Target.setAutoAttach"}}
      when method != "Target.setAutoAttach" ->
        answer(fake, id, :ok)
        expect_call(fake, method, outcome)
    after
      2_000 -> flunk("no #{method} call")
    end
  end

  # The same for a call on one session (`nil`: the page's own, no sessionId).
  defp expect_call_on(fake, method, sid, outcome \\ :ok) do
    receive do
      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => ^method, "sessionId" => ^sid} = frame}
      when is_binary(sid) ->
        answer(fake, id, outcome)
        frame["params"] || %{}

      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => ^method} = frame}
      when sid == nil and not is_map_key(frame, "sessionId") ->
        answer(fake, id, outcome)
        frame["params"] || %{}

      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Target.setAutoAttach"}}
      when method != "Target.setAutoAttach" ->
        answer(fake, id, :ok)
        expect_call_on(fake, method, sid, outcome)
    after
      2_000 -> flunk("no #{method} call on #{inspect(sid)}")
    end
  end

  defp answer(fake, id, :ok), do: FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

  defp answer(fake, id, :error),
    do: FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}}))

  defp event(fake, method, params, sid \\ nil) do
    frame = %{"method" => method, "params" => params}
    frame = if sid, do: Map.put(frame, "sessionId", sid), else: frame
    FakeCDP.send_text(fake, Jason.encode!(frame))
  end

  defp attach(fake, child, parent \\ nil, type \\ "iframe") do
    event(
      fake,
      "Target.attachedToTarget",
      %{
        "sessionId" => child,
        "targetInfo" => %{"targetId" => "T-" <> child, "type" => type},
        "waitingForDebugger" => true
      },
      parent
    )
  end

  # The owner's answer to an iframe attach: filter it, auto-attach its own iframes,
  # resume it — on the iframe's session, in that order.
  defp expect_iframe_armed(fake, child) do
    params = expect_call_on(fake, "Fetch.enable", child)
    assert expect_call_on(fake, "Target.setAutoAttach", child) == @auto_attach
    expect_call_on(fake, "Runtime.runIfWaitingForDebugger", child)
    params
  end

  # Observe the console from `observer`; answers the auto-attach it turns on.
  defp observe(pid, fake, observer, methods \\ @console) do
    tag = make_ref()
    Fetch.request(pid, tag, {:observe_console, observer, methods, 5_000})

    receive do
      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Target.setAutoAttach"}} ->
        answer(fake, id, :ok)
    after
      200 -> :ok
    end

    assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
  end

  # The owner's answer to an iframe attach with console observers and no Fetch mode.
  defp expect_console_armed(fake, child) do
    expect_call_on(fake, "Runtime.enable", child)
    assert expect_call_on(fake, "Target.setAutoAttach", child) == @auto_attach
    expect_call_on(fake, "Runtime.runIfWaitingForDebugger", child)
  end

  # Like expect_call_on/3, but answers no Target.setAutoAttach on the way, so a test can
  # check one never came.
  defp expect_strict(fake, method, sid) do
    receive do
      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => ^method} = frame} ->
        assert frame["sessionId"] == sid
        answer(fake, id, :ok)
        frame["params"] || %{}

      {:fake_cdp_recv, ^fake, other} ->
        flunk("expected #{method}, got #{inspect(other)}")
    after
      2_000 -> flunk("no #{method} call")
    end
  end

  defp pause_on(fake, sid, id, url, type) do
    params = %{"requestId" => id, "request" => %{"url" => url}, "resourceType" => type}
    event(fake, "Fetch.requestPaused", params, sid)
  end

  defp pause(fake, id, url, type) do
    params = %{"requestId" => id, "request" => %{"url" => url}, "resourceType" => type}
    FakeCDP.send_text(fake, Jason.encode!(%{"method" => "Fetch.requestPaused", "params" => params}))
  end

  # An interception owner the test can kill: relays what it gets to the test.
  defp relay_owner do
    test = self()

    spawn(fn ->
      relay = fn relay ->
        receive do
          msg ->
            send(test, {:owner_got, msg})
            relay.(relay)
        end
      end

      relay.(relay)
    end)
  end
end
