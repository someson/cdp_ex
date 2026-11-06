defmodule CDPEx.ChromeTest do
  # async: false — these touch process env vars and (in the integration case)
  # launch a real OS process.
  use ExUnit.Case, async: false

  alias CDPEx.Chrome

  describe "resolve_binary/1" do
    setup do
      # Snapshot and clear the env vars so each test controls them explicitly.
      saved = {System.get_env("CDP_EX_CHROME_BINARY"), System.get_env("CHROME_BINARY")}
      System.delete_env("CDP_EX_CHROME_BINARY")
      System.delete_env("CHROME_BINARY")

      on_exit(fn ->
        {a, b} = saved

        if a,
          do: System.put_env("CDP_EX_CHROME_BINARY", a),
          else: System.delete_env("CDP_EX_CHROME_BINARY")

        if b, do: System.put_env("CHROME_BINARY", b), else: System.delete_env("CHROME_BINARY")
      end)
    end

    test "the :chrome_binary option wins over everything" do
      System.put_env("CDP_EX_CHROME_BINARY", "/from/env")
      assert Chrome.resolve_binary(chrome_binary: "/explicit/chrome") == "/explicit/chrome"
    end

    test "CDP_EX_CHROME_BINARY wins over CHROME_BINARY" do
      System.put_env("CDP_EX_CHROME_BINARY", "/cdp/ex/chrome")
      System.put_env("CHROME_BINARY", "/generic/chrome")
      assert Chrome.resolve_binary([]) == "/cdp/ex/chrome"
    end

    test "falls back to CHROME_BINARY" do
      System.put_env("CHROME_BINARY", "/generic/chrome")
      assert Chrome.resolve_binary([]) == "/generic/chrome"
    end

    test "falls back to an OS default when nothing is set" do
      # We don't assert the exact path (OS-dependent) — just that it's a non-empty
      # absolute path, not nil.
      path = Chrome.resolve_binary([])
      assert is_binary(path) and path != ""
    end
  end

  describe "default_args/2" do
    test "includes --headless by default" do
      assert "--headless" in Chrome.default_args("/tmp/p")
    end

    test "omits --headless when headless: false" do
      refute "--headless" in Chrome.default_args("/tmp/p", headless: false)
    end

    test "wires the profile dir and remote debugging port" do
      args = Chrome.default_args("/tmp/profile")
      assert "--user-data-dir=/tmp/profile" in args
      assert "--remote-debugging-port=0" in args
    end

    test "pipe: true swaps the debugging port for the pipe" do
      args = Chrome.default_args("/tmp/p", pipe: true)
      assert "--remote-debugging-pipe" in args
      refute "--remote-debugging-port=0" in args
    end

    test "applies a custom window size" do
      assert "--window-size=800,600" in Chrome.default_args("/tmp/p", window_size: {800, 600})
    end

    test "ends with the about:blank initial target" do
      assert List.last(Chrome.default_args("/tmp/p")) == "about:blank"
    end

    test "disables the field-trial testing config" do
      assert "--disable-field-trial-config" in Chrome.default_args("/tmp/p")
    end

    test "disables component extensions with background pages" do
      assert "--disable-component-extensions-with-background-pages" in Chrome.default_args("/tmp/p")
    end

    test "turns off Chrome's own background services" do
      args = Chrome.default_args("/tmp/p")

      for flag <- [
            "--disable-sync",
            "--metrics-recording-only",
            "--no-service-autorun",
            "--disable-client-side-phishing-detection",
            "--disable-domain-reliability",
            "--disable-default-apps",
            "--password-store=basic",
            "--use-mock-keychain"
          ] do
        assert flag in args
      end

      assert ("--disable-features=OptimizationHints,OptimizationGuideModelDownloading," <>
                "NetworkTimeServiceQuerying,SafeBrowsingHashPrefixRealTimeLookups,PreconnectToSearch") in args
    end

    test "keeps Google's sign-in and updater hosts off the network by default" do
      args = Chrome.default_args("/tmp/p")
      assert "--proxy-bypass-list=accounts.google.com;update.googleapis.com" in args

      assert "--host-resolver-rules=MAP accounts.google.com ~NOTFOUND, MAP update.googleapis.com ~NOTFOUND" in args
    end

    test "block_background_hosts: false leaves those hosts alone" do
      args = Chrome.default_args("/tmp/p", block_background_hosts: false)
      refute Enum.any?(args, &String.starts_with?(&1, "--proxy-bypass-list"))
      refute Enum.any?(args, &String.starts_with?(&1, "--host-resolver-rules"))
    end

    test "ships no anti-bot defaults" do
      args = Chrome.default_args("/tmp/p")
      refute Enum.any?(args, &String.contains?(&1, "AutomationControlled"))
      refute "--disable-web-security" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--user-agent"))
    end
  end

  describe "validate_opts!/2 :block_background_hosts" do
    test "takes a boolean" do
      assert :ok = Chrome.validate_opts!(block_background_hosts: false)

      assert_raise ArgumentError, ~r/invalid :block_background_hosts "no"/, fn ->
        Chrome.validate_opts!(block_background_hosts: "no")
      end
    end
  end

  describe "spawn_command/2" do
    @tag skip: match?({:win32, _}, :os.type()) && "no /bin/sh watchdog on Windows"
    test "runs Chrome under the /bin/sh watchdog, with its args passed through" do
      assert {"/bin/sh", ["-c", script, "/opt/chrome", "--headless", "about:blank"]} =
               Chrome.spawn_command("/opt/chrome", ["--headless", "about:blank"])

      assert script =~ ~s(exec "$0" "$@")
    end

    test "pipe: true maps the Port's stdin and stdout onto Chrome's fds 3 and 4" do
      assert {"/bin/sh", ["-c", script, "/opt/chrome", "--remote-debugging-pipe"]} =
               Chrome.spawn_command("/opt/chrome", ["--remote-debugging-pipe"], true)

      assert script =~ "3<&0 4>&1"
      # Chrome's own output must stay off the CDP stream.
      assert script =~ "1>/dev/null 2>/dev/null"
    end
  end

  describe "validate_opts!/1 for :pipe" do
    test "accepts booleans on Unix" do
      assert Chrome.validate_opts!([pipe: false], {:unix, :linux}) == :ok
      assert Chrome.validate_opts!([pipe: true], {:unix, :linux}) == :ok
      assert Chrome.validate_opts!([pipe: true], {:unix, :darwin}) == :ok
    end

    test "rejects pipe: true on Windows, before anything is launched" do
      assert_raise ArgumentError, ~r/invalid :pipe true .*not on Windows/, fn ->
        Chrome.validate_opts!([pipe: true], {:win32, :nt})
      end

      assert Chrome.validate_opts!([pipe: false], {:win32, :nt}) == :ok
    end

    test "rejects anything else" do
      assert_raise ArgumentError, ~r/invalid :pipe "yes"/, fn ->
        Chrome.validate_opts!(pipe: "yes")
      end
    end
  end

  describe "build_args/2" do
    test "appends :extra_args to the defaults" do
      args = Chrome.build_args("/tmp/p", extra_args: ["--proxy-server=http://x:1"])
      assert "--proxy-server=http://x:1" in args
      assert "--headless" in args
    end

    test "a --disable-features in :extra_args joins the default list" do
      args = Chrome.build_args("/tmp/p", extra_args: ["--disable-features=Translate"])
      [flag] = Enum.filter(args, &String.starts_with?(&1, "--disable-features="))
      assert flag =~ ~r/^--disable-features=OptimizationHints,.*,PreconnectToSearch,Translate$/
    end

    test "a feature in --enable-features is dropped from the default disable list" do
      args = Chrome.build_args("/tmp/p", extra_args: ["--enable-features=OptimizationHints"])
      [flag] = Enum.filter(args, &String.starts_with?(&1, "--disable-features="))
      refute flag =~ "OptimizationHints,"
      assert flag =~ "OptimizationGuideModelDownloading"
      assert "--enable-features=OptimizationHints" in args
    end

    test "a bypass list and resolver rules in :extra_args join the defaults" do
      args =
        Chrome.build_args("/tmp/p",
          extra_args: ["--proxy-bypass-list=*.local", "--host-resolver-rules=MAP x.test 127.0.0.1"]
        )

      assert Enum.filter(args, &String.starts_with?(&1, "--proxy-bypass-list=")) ==
               ["--proxy-bypass-list=accounts.google.com;update.googleapis.com;*.local"]

      assert Enum.filter(args, &String.starts_with?(&1, "--host-resolver-rules=")) == [
               "--host-resolver-rules=MAP accounts.google.com ~NOTFOUND, " <>
                 "MAP update.googleapis.com ~NOTFOUND, MAP x.test 127.0.0.1"
             ]
    end

    test "with block_background_hosts: false, a user bypass list stays as given" do
      args =
        Chrome.build_args("/tmp/p",
          block_background_hosts: false,
          extra_args: ["--proxy-bypass-list=*.local"]
        )

      assert Enum.filter(args, &String.starts_with?(&1, "--proxy-bypass-list=")) ==
               ["--proxy-bypass-list=*.local"]
    end

    test ":extra_args given as charlists merge too" do
      args = Chrome.build_args("/tmp/p", extra_args: [~c"--disable-features=Translate"])
      assert length(Enum.filter(args, &String.starts_with?(&1, "--disable-features="))) == 1
    end

    test ":args fully replaces the defaults" do
      args = Chrome.build_args("/tmp/p", args: ["--only", "--these"])
      assert args == ["--only", "--these"]
      refute "--headless" in args
    end
  end

  describe "create_temp_profile_dir/2" do
    @describetag :tmp_dir

    test "names the dir after this OS process and creates it", %{tmp_dir: tmp} do
      assert {:ok, dir, true} = Chrome.create_temp_profile_dir(tmp)
      assert Path.basename(dir) =~ ~r/^cdp_ex-#{System.pid()}-\d+$/
      assert File.dir?(dir)
    end

    test "marks the dir with its owner, so only a matching sweep removes it", %{tmp_dir: tmp} do
      assert {:ok, dir, true} = Chrome.create_temp_profile_dir(tmp)
      assert File.read!(Path.join(dir, ".cdp_ex_owner")) == Chrome.owner_id()
    end

    test "returns a different dir on each call", %{tmp_dir: tmp} do
      assert {:ok, a, true} = Chrome.create_temp_profile_dir(tmp)
      assert {:ok, b, true} = Chrome.create_temp_profile_dir(tmp)
      refute a == b
    end

    test "never reuses a dir that already exists", %{tmp_dir: tmp} do
      taken = Path.join(tmp, "taken")
      File.mkdir!(taken)
      File.write!(Path.join(taken, "SingletonLock"), "")

      {:ok, names} = Agent.start_link(fn -> ["taken", "free"] end)
      next = fn -> Agent.get_and_update(names, fn [n | rest] -> {n, rest} end) end

      assert Chrome.create_temp_profile_dir(tmp, next) == {:ok, Path.join(tmp, "free"), true}
      assert File.exists?(Path.join(taken, "SingletonLock"))
    end

    test "gives up with :eexist when every name is taken", %{tmp_dir: tmp} do
      File.mkdir!(Path.join(tmp, "taken"))

      assert Chrome.create_temp_profile_dir(tmp, fn -> "taken" end) ==
               {:error, {:launch_failed, {:user_data_dir, :eexist}}}
    end

    test "reports other mkdir failures as {:user_data_dir, posix}", %{tmp_dir: tmp} do
      file = Path.join(tmp, "a_file")
      File.write!(file, "")

      assert Chrome.create_temp_profile_dir(file, fn -> "p" end) ==
               {:error, {:launch_failed, {:user_data_dir, :enotdir}}}
    end
  end

  describe "sweep_stale_profile_dirs/1" do
    @describetag :tmp_dir

    test "removes the profile dirs of a dead OS pid", %{tmp_dir: tmp} do
      dead = dead_os_pid()
      dirs = for n <- [1, 42], do: owned_dir!(tmp, "cdp_ex-#{dead}-#{n}", Chrome.owner_id())
      File.write!(Path.join(hd(dirs), "SingletonLock"), "")

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      refute Enum.any?(dirs, &File.exists?/1)
    end

    test "keeps a dead pid's dir made on another host or in another pid namespace", %{
      tmp_dir: tmp
    } do
      dead = dead_os_pid()
      foreign = owned_dir!(tmp, "cdp_ex-#{dead}-1", "other-host\npid:[1]\n")
      unmarked = mkdir!(tmp, "cdp_ex-#{dead}-2")

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      assert File.dir?(foreign)
      assert File.dir?(unmarked)
    end

    test "trusts only the marker that matches the owner it is given", %{tmp_dir: tmp} do
      dead = dead_os_pid()
      dir = owned_dir!(tmp, "cdp_ex-#{dead}-1", "host-b\npid:[7]\n")

      assert Chrome.sweep_stale_profile_dirs(tmp, "host-a\npid:[7]\n") == :ok
      assert File.dir?(dir)
      assert Chrome.sweep_stale_profile_dirs(tmp, "host-b\npid:[7]\n") == :ok
      refute File.exists?(dir)
    end

    test "keeps the profile dirs of this VM", %{tmp_dir: tmp} do
      dir = owned_dir!(tmp, "cdp_ex-#{System.pid()}-1", Chrome.owner_id())

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      assert File.dir?(dir)
    end

    test "keeps the profile dirs of another live OS process", %{tmp_dir: tmp} do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["30"]])
      {:os_pid, live} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", ["-9", to_string(live)]) end)
      dir = owned_dir!(tmp, "cdp_ex-#{live}-1", Chrome.owner_id())

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      assert File.dir?(dir)
    end

    test "keeps anything not named exactly cdp_ex-<pid>-<n>", %{tmp_dir: tmp} do
      dead = dead_os_pid()

      names = [
        "cdp_ex-#{dead}",
        "cdp_ex-#{dead}-",
        "cdp_ex-#{dead}-1-x",
        "cdp_ex-#{dead}-01",
        "cdp_ex-0#{dead}-1",
        "cdp_ex-abc-1",
        "xcdp_ex-#{dead}-1",
        "cdp_ex-#{dead}-1.bak",
        "other"
      ]

      dirs = Enum.map(names, &owned_dir!(tmp, &1, Chrome.owner_id()))

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      assert Enum.all?(dirs, &File.dir?/1)
    end

    test "keeps a regular file or a symlink with a matching name", %{tmp_dir: tmp} do
      dead = dead_os_pid()
      file = Path.join(tmp, "cdp_ex-#{dead}-1")
      File.write!(file, "")
      target = owned_dir!(tmp, "target", Chrome.owner_id())
      File.write!(Path.join(target, "keep"), "")
      link = Path.join(tmp, "cdp_ex-#{dead}-2")
      File.ln_s!(target, link)

      assert Chrome.sweep_stale_profile_dirs(tmp) == :ok
      assert File.regular?(file)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert File.exists?(Path.join(target, "keep"))
    end

    test "returns :ok when the temp dir can't be listed", %{tmp_dir: tmp} do
      assert Chrome.sweep_stale_profile_dirs(Path.join(tmp, "missing")) == :ok
    end
  end

  describe "launch/1" do
    test "returns chrome_not_found for a missing binary" do
      assert {:error, {:chrome_not_found, "/no/such/chrome"}} =
               Chrome.launch(chrome_binary: "/no/such/chrome")
    end

    test "returns chrome_not_found for a directory" do
      dir = System.tmp_dir!()
      assert {:error, {:chrome_not_found, ^dir}} = Chrome.launch(chrome_binary: dir)
    end

    @tag :tmp_dir
    test "returns chrome_not_found for a non-executable file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "not-chrome")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o644)

      assert {:error, {:chrome_not_found, ^path}} = Chrome.launch(chrome_binary: path)
    end

    @tag :tmp_dir
    test "times out to {:debug_url_not_found, stderr} when the endpoint never appears", %{
      tmp_dir: tmp_dir
    } do
      # A stand-in binary that prints to stderr and stays alive without ever
      # exposing a DevTools endpoint (no ws:// line, no DevToolsActivePort file).
      stub =
        write_stub!(tmp_dir, "stub-no-endpoint", """
        #!/bin/sh
        # exec, so the shell flushes the buffered stderr line to the pipe before
        # sleeping (a plain `sleep` would hold it unflushed past the timeout).
        echo 'stub-chrome: no devtools endpoint here' 1>&2
        exec sleep 30
        """)

      # A generous timeout: this path always waits it out (no endpoint ever
      # appears), and the captured stderr must arrive before the deadline even
      # under concurrent test load — a tight window races the port data delivery.
      assert {:error, {:debug_url_not_found, excerpt}} =
               Chrome.launch(chrome_binary: stub, launch_timeout: 2_000)

      # The captured stderr is threaded into the error, so the failure is
      # self-diagnosing rather than a context-free atom.
      assert excerpt =~ "no devtools endpoint"
    end

    @tag :tmp_dir
    test "returns as soon as DevToolsActivePort is readable, without the stderr line", %{
      tmp_dir: tmp_dir
    } do
      # Writes a valid DevToolsActivePort into its --user-data-dir but never prints
      # the "DevTools listening on ws://" line — the case that used to block for the
      # full timeout. The poll must pick the file up and return promptly.
      stub =
        write_stub!(tmp_dir, "stub-writes-port", """
        #!/bin/sh
        dir=""
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) dir="${arg#--user-data-dir=}" ;;
          esac
        done
        {
          echo '9222'
          echo '/devtools/browser/stub-uuid'
        } > "$dir/DevToolsActivePort"
        echo 'stub-chrome: started without a listening line' 1>&2
        sleep 30
        """)

      {elapsed_us, result} =
        :timer.tc(fn -> Chrome.launch(chrome_binary: stub, launch_timeout: 5_000) end)

      assert {:ok, handle} = result
      assert handle.debug_url == "ws://127.0.0.1:9222/devtools/browser/stub-uuid"
      # Returned on a poll tick, far under the 5s ceiling — not by waiting it out.
      assert elapsed_us < 2_000_000

      :ok = Chrome.stop(handle)
      refute File.dir?(handle.user_data_dir)
    end

    @tag :tmp_dir
    test "returns {:devtools_file_malformed, excerpt} for an unparseable DevToolsActivePort", %{
      tmp_dir: tmp_dir
    } do
      # Writes a DevToolsActivePort that exists but doesn't parse (no port/path
      # lines) — the terminal reason carries the contents excerpt, not a bare atom.
      stub =
        write_stub!(tmp_dir, "stub-malformed-port", """
        #!/bin/sh
        dir=""
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) dir="${arg#--user-data-dir=}" ;;
          esac
        done
        echo 'not-a-valid-devtools-port-file' > "$dir/DevToolsActivePort"
        echo 'stub-chrome: wrote a malformed port file' 1>&2
        sleep 30
        """)

      assert {:error, {:devtools_file_malformed, excerpt}} =
               Chrome.launch(chrome_binary: stub, launch_timeout: 2_000)

      assert excerpt =~ "not-a-valid-devtools-port-file"
    end

    @tag :tmp_dir
    test "pipe: true returns once the stand-in answers the probe on fd 4", %{tmp_dir: tmp_dir} do
      stub =
        write_stub!(tmp_dir, "stub-pipe", """
        #!/bin/sh
        printf '{"id":0,"result":{"product":"stub"}}\\000' >&4
        exec sleep 30
        """)

      assert {:ok, handle} = Chrome.launch(chrome_binary: stub, pipe: true, launch_timeout: 5_000)
      assert handle.pipe
      assert handle.debug_url == nil
      assert is_integer(handle.os_pid)

      :ok = Chrome.stop(handle)
      refute File.dir?(handle.user_data_dir)
    end

    @tag :tmp_dir
    test "pipe: true times out to {:debug_url_not_found, \"\"} when nothing answers", %{
      tmp_dir: tmp_dir
    } do
      stub =
        write_stub!(tmp_dir, "stub-pipe-silent", """
        #!/bin/sh
        exec sleep 30
        """)

      {elapsed_us, result} =
        :timer.tc(fn -> Chrome.launch(chrome_binary: stub, pipe: true, launch_timeout: 300) end)

      assert result == {:error, {:debug_url_not_found, ""}}
      assert elapsed_us < 3_000_000
    end

    @tag :tmp_dir
    test "pipe: true reports an exit before the answer as {:chrome_exited, status, \"\"}", %{
      tmp_dir: tmp_dir
    } do
      stub =
        write_stub!(tmp_dir, "stub-pipe-exits", """
        #!/bin/sh
        echo 'stderr is dropped in pipe mode' 1>&2
        exit 3
        """)

      assert Chrome.launch(chrome_binary: stub, pipe: true, launch_timeout: 5_000) ==
               {:error, {:chrome_exited, 3, ""}}
    end

    @tag :tmp_dir
    test "pipe: true rejects an answer that isn't the probe's reply", %{tmp_dir: tmp_dir} do
      stub =
        write_stub!(tmp_dir, "stub-pipe-garbage", """
        #!/bin/sh
        printf 'not json\\000' >&4
        exec sleep 30
        """)

      assert Chrome.launch(chrome_binary: stub, pipe: true, launch_timeout: 5_000) ==
               {:error, {:debug_url_not_found, "not json"}}
    end

    @tag :integration
    test "launches real Chrome, exposes a browser ws URL, and cleans up on stop" do
      assert {:ok, handle} = Chrome.launch([])
      assert handle.debug_url =~ ~r{^ws://[^/]+/devtools/browser/}
      assert is_integer(handle.os_pid)
      assert File.dir?(handle.user_data_dir)

      :ok = Chrome.stop(handle)

      # Temp profile dir we created is gone after stop.
      refute File.dir?(handle.user_data_dir)
    end
  end

  # Write an executable stand-in "chrome" script into a tmp dir for launch/1 tests
  # that exercise the readiness path without a real browser.
  defp write_stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp owned_dir!(tmp, name, owner) do
    dir = mkdir!(tmp, name)
    File.write!(Path.join(dir, ".cdp_ex_owner"), owner)
    dir
  end

  defp mkdir!(tmp, name) do
    dir = Path.join(tmp, name)
    File.mkdir!(dir)
    dir
  end

  # The OS pid of a process that has run and exited (and been reaped), so `kill -0`
  # reports it gone until the OS reuses the pid.
  defp dead_os_pid do
    port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert_receive {^port, {:exit_status, 0}}, 5_000
    refute match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
    os_pid
  end
end
