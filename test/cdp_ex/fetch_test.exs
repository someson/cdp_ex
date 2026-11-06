defmodule CDPEx.FetchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Fetch

  @creds [username: "u", password: "p"]
  @auth %{username: "u", password: "p", source: :any}

  describe "auth_decision/5" do
    test "provides credentials for a matching challenge and records the attempt" do
      {response, attempts} = Fetch.auth_decision(:any, %{}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{
               "response" => "ProvideCredentials",
               "username" => "u",
               "password" => "p"
             }

      assert attempts == %{"R1" => 1}
    end

    test "cancels on the second challenge for the same request (rejected credentials)" do
      {response, attempts} =
        Fetch.auth_decision(:any, %{"R1" => 1}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{"response" => "CancelAuth"}
      refute Map.has_key?(attempts, "R1")
    end

    test "the :proxy filter answers only Proxy challenges" do
      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end

    test "the :server filter answers only Server challenges" do
      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end

    test "caps the attempts map so answered-but-unpruned challenges can't grow it unbounded" do
      # Only the rejection path deletes; a successful answer leaves its entry. At the
      # cap a fresh challenge resets the map rather than growing it without bound.
      full = Map.new(1..1024, &{"R#{&1}", 1})
      assert map_size(full) == 1024

      assert {%{"response" => "ProvideCredentials"}, %{"NEW" => 1}} =
               Fetch.auth_decision(:any, full, "NEW", %{"source" => "Server"}, @creds)
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

    test "without block or auth every pause is the owner's (Chrome applied its patterns)" do
      state = with_modes(nil, [%{"resourceType" => "Image"}])
      assert Fetch.decide(state, paused("https://a/")) == :forward
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
      Fetch.request(pid, tag, {:auth, @auth})
      assert expect_call(fake, "Fetch.enable") == %{"handleAuthRequests" => true}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      tag2 = make_ref()
      Fetch.request(pid, tag2, {:auth, @auth})
      assert_receive {:fetch_reply, ^pid, ^tag2, {:error, :already_authenticated}}, 2_000
    end

    test "a failed enable leaves the mode off, so a retry can arm it", %{conn: conn, fake: fake} do
      pid = start_owner(conn)

      log =
        capture_log(fn ->
          tag = make_ref()
          Fetch.request(pid, tag, {:auth, @auth})
          expect_call(fake, "Fetch.enable", :error)

          assert_receive {:fetch_reply, ^pid, ^tag, {:error, {:cdp_error, "Fetch.enable", _}}},
                         2_000
        end)

      assert log =~ "arming failed"

      tag = make_ref()
      Fetch.request(pid, tag, {:auth, @auth})
      expect_call(fake, "Fetch.enable")
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "interception alone sends the caller's patterns and forwards every pause", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      patterns = [%{"resourceType" => "Image"}]

      tag = make_ref()
      Fetch.request(pid, tag, {:intercept, self(), patterns, 5_000})
      assert expect_call(fake, "Fetch.enable") == %{"patterns" => patterns}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

      pause(fake, "r1", "https://a.test/", "Document")
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
      arm(pid, fake, {:auth, @auth})

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
      Fetch.request(pid, tag, {:auth, @auth})

      assert %{"handleAuthRequests" => true, "patterns" => [%{"urlPattern" => "*"}]} =
               expect_call(fake, "Fetch.enable")

      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000
    end

    test "an owner that dies with auth on: its pauses are let through, auth re-armed alone", %{
      conn: conn,
      fake: fake
    } do
      pid = start_owner(conn)
      arm(pid, fake, {:auth, @auth})
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
      arm(pid, fake, {:auth, @auth})
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
      Fetch.request(pid, tag, {:auth, @auth})
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
      arm(pid, fake, {:auth, @auth})

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
      arm(pid, fake, {:auth, @auth})

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
      arm(pid, fake, {:auth, @auth})

      tag = make_ref()
      Fetch.request(pid, tag, {:block, ["Image"], 5_000})
      assert expect_call(fake, "Fetch.enable") == %{"handleAuthRequests" => true}
      assert_receive {:fetch_reply, ^pid, ^tag, :ok}, 2_000

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

    test "terminate disables Fetch when only block is on", %{conn: conn, fake: fake} do
      pid = start_owner(conn)
      arm(pid, fake, {:block, ["Image"], 5_000})

      stopper = Task.async(fn -> GenServer.stop(pid) end)
      expect_call(fake, "Fetch.disable")
      Task.await(stopper)
    end
  end

  defp start_owner(conn) do
    {:ok, pid} = Fetch.start_link(conn: conn, browser: self())
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
  defp expect_call(fake, method, outcome \\ :ok) do
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => ^method} = frame}, 2_000

    case outcome do
      :ok -> FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      :error -> FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}}))
    end

    frame["params"] || %{}
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
