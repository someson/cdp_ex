defmodule CDPEx.Chrome do
  @moduledoc """
  Launches, discovers, and stops the headless Chrome OS process.

  `launch/1` opens Chrome via a `Port` with `--remote-debugging-port=0`, reads
  the chosen DevTools WebSocket URL from Chrome's stderr (falling back to the
  `DevToolsActivePort` file), and returns a handle. `stop/1` kills the process
  and removes the temp profile.

  With `pipe: true` Chrome gets `--remote-debugging-pipe` instead: it reads CDP on
  fd 3 and writes it on fd 4, which a `/bin/sh` wrapper maps onto the Port's stdin
  and stdout. No TCP port is opened, and `launch/1` returns as soon as Chrome
  answers a first command on the pipe. Chrome's own stdout and stderr go to
  `/dev/null`, so a failed launch carries no stderr excerpt. Chrome exits by itself
  when the pipe closes, which is what reaps it when the VM exits without running
  `terminate/2`; the stdin watchdog below can't run, since stdin carries CDP.

  Without `:pipe`, on Unix, Chrome runs under a small `/bin/sh` watchdog that kills it when the
  Port's stdin closes, so Chrome doesn't outlive the VM even when the VM exits
  without running `terminate/2` (`System.halt/1`, `kill -9`, the OOM killer).
  Chrome still has the Port's OS pid. The temp profile dir stays behind in that
  case, since nothing in the VM is left to remove it.

  The argument and discovery helpers (`build_args/2`, `default_args/2`,
  `resolve_binary/1`) are pure and unit-testable without launching anything.

  ## Launch options

    * `:headless` — run headless (default `true`); `false` drops `--headless`
    * `:chrome_binary` — path to the Chrome/Chromium executable
    * `:window_size` — `{width, height}` (default `{1280, 1024}`)
    * `:user_data_dir` — profile dir; a fresh temp dir is created (and removed on
      stop) when omitted. A caller-supplied dir is left in place.
    * `:extra_args` — extra flags appended to the defaults
    * `:args` — full flag list that **replaces** the defaults entirely
    * `:pipe` — `true` talks CDP over `--remote-debugging-pipe` instead of a
      WebSocket (default `false`). Pages on such a browser are `:session` pages only.
      Unix only: `true` raises `ArgumentError` on Windows. With a full `:args` list,
      include `--remote-debugging-pipe` yourself.
    * `:launch_timeout` — ms to wait for the DevTools endpoint (default
      `15_000`). A *ceiling*, not a fixed wait: readiness is polled and returns
      as soon as Chrome is reachable, so a generous value is free. Raise it for
      slow cold-start hosts (e.g. headless Chrome in a constrained container).

  An invalid value for any of these raises `ArgumentError` in the caller (except the
  options a full `:args` list replaces, which are never read).

  ## Default flags

  Defaults are deliberately neutral (stability + headless), not scraping-tuned.
  They include `--disable-field-trial-config`, so a Chromium or Chrome for Testing
  build runs without the experimental features its bundled field-trial testing
  config would otherwise turn on (the same default Puppeteer and Playwright use),
  and `--disable-component-extensions-with-background-pages`, so built-in
  extensions don't keep an extension process alive (Playwright's default too).
  Anti-bot flags (spoofed user-agent, `--disable-web-security`,
  `--disable-blink-features=AutomationControlled`, …) are **not** included — add
  them via `:extra_args` if you need them.

  > #### Sandbox {: .warning}
  >
  > The defaults include `--no-sandbox` / `--disable-setuid-sandbox` so Chrome
  > starts in the common container/CI setup (running as root), where the sandbox
  > can't initialize. That is a security reduction when visiting untrusted pages —
  > to keep the sandbox, run as a non-root user and override the flag list via
  > `:args` (omitting the two sandbox flags).
  """

  import Bitwise, only: [band: 2]

  alias CDPEx.Protocol

  @launch_timeout 15_000

  # On Unix, Chrome is started through this /bin/sh script rather than directly, so
  # it can't outlive the VM. `terminate/2` reaps Chrome on every exit path inside a
  # running VM, but nothing runs when the VM itself goes away (`System.halt/1`, a
  # crashing script, `kill -9`, the OOM killer), and Chrome ignores its stdin, so the
  # Port closing doesn't stop it either. The script starts a background watchdog
  # that blocks reading the Port's stdin, then execs Chrome in its own place, so
  # Chrome keeps the Port's OS pid (`kill/1`, `await_exit/2` and the process label
  # are unchanged). The OS closes that pipe when the VM exits, however it exits;
  # the watchdog's read then returns and it kill -9s Chrome. On a normal stop it
  # fires after `stop/1` already killed Chrome, which is harmless.
  #
  # fd 3 carries stdin into the watchdog because POSIX shells give a background
  # job /dev/null as stdin. The watchdog drops stdout/stderr so it doesn't hold the
  # Port open after Chrome exits (the exit status only arrives once they close), and
  # Chrome gets fd 3 closed. If the exec itself fails, the shell exits 126 (not
  # executable) or 127 (not found) before Chrome runs; see exit_reason/1.
  @watchdog ~S|exec 3<&0; (read -r _ <&3; kill -9 $$) >/dev/null 2>&1 & exec "$0" "$@" 3<&-|

  # The `pipe: true` wrapper: Chrome's --remote-debugging-pipe reads fd 3 and writes
  # fd 4, so the Port's stdin and stdout move there, and Chrome's own stdout and
  # stderr go to /dev/null (anything else written to the Port's stdout would corrupt
  # the CDP stream). exec keeps the Port's OS pid, as with @watchdog. No watchdog: it
  # would have to read stdin, which now carries CDP. Chrome instead exits when fd 3
  # reaches EOF, which the OS delivers when the VM exits, however it exits.
  @pipe_wrapper ~S|exec "$0" "$@" 3<&0 4>&1 0</dev/null 1>/dev/null 2>/dev/null|

  # The readiness probe sent on the pipe. Its id is 0 so it can't collide with the
  # ids CDPEx.Connection numbers from 1.
  @pipe_probe ~S|{"id":0,"method":"Browser.getVersion","params":{}}|

  # Fresh names to try when a temp profile dir already exists (see create_temp_profile_dir/2).
  @temp_dir_attempts 10

  # How often to poll the DevToolsActivePort file while waiting for readiness, so
  # a fast-ready Chrome returns promptly and @launch_timeout acts as a ceiling.
  @devtools_poll_interval 150
  @stop_exit_timeout 3_000
  @default_window_size {1280, 1024}

  @type handle :: %{
          port: port(),
          os_pid: non_neg_integer() | nil,
          debug_url: String.t() | nil,
          pipe: boolean(),
          user_data_dir: String.t(),
          owns_data_dir: boolean()
        }

  @doc """
  Launches headless Chrome and returns `{:ok, handle}` once its DevTools
  endpoint is reachable, or `{:error, reason}`.

  The `Port` is owned by the calling process, which therefore receives the
  `{port, {:exit_status, _}}` message if Chrome dies. With `pipe: true` the
  handle's `debug_url` is `nil` and the Port carries CDP: hand it to
  `CDPEx.Connection` with `Port.connect/2` before sending anything else on it.
  A pipe launch that gets no answer within `:launch_timeout` returns
  `{:error, {:debug_url_not_found, ""}}`.
  """
  @typedoc """
  Error reasons from `launch/1`. Precisely specced (not `term()`) so Dialyzer flags
  drift at the source.
  """
  @type launch_error ::
          {:chrome_not_found, String.t()}
          | {:debug_url_not_found, String.t()}
          | {:devtools_file_malformed, String.t()}
          | {:chrome_exited, integer(), String.t()}
          | {:launch_failed, {:user_data_dir | :spawn, term()}}

  @spec launch(keyword()) :: {:ok, handle()} | {:error, launch_error()}
  def launch(opts \\ []) do
    validate_opts!(opts)
    binary = resolve_binary(opts)

    if executable?(binary) do
      do_launch(binary, opts)
    else
      {:error, {:chrome_not_found, binary}}
    end
  end

  @doc false
  # `os_type` is `:os.type()`; a test passes another to check the Windows rules on Unix.
  @spec validate_opts!(keyword(), {atom(), atom()}) :: :ok
  def validate_opts!(opts, os_type \\ :os.type()) do
    # A full :args override means build_args/2 never reads these, so they launched fine.
    ignored =
      if is_list(Keyword.get(opts, :args)), do: [:headless, :window_size, :extra_args], else: []

    # Keyword.get/3 reads only a key's first occurrence, so a shadowed duplicate never mattered.
    opts
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.each(fn {key, value} ->
      if key not in ignored and !valid_opt?(key, value, os_type) do
        raise ArgumentError, "invalid #{inspect(key)} #{inspect(value)} (expected #{expected(key)})"
      end
    end)
  end

  # Remapping fds 3 and 4 for the pipe needs /bin/sh, which Windows lacks.
  defp valid_opt?(:pipe, true, os_type), do: not match?({:win32, _}, os_type)
  defp valid_opt?(key, value, _os_type), do: valid_opt?(key, value)

  defp valid_opt?(:headless, value), do: is_boolean(value)
  defp valid_opt?(:pipe, value), do: value == false
  defp valid_opt?(:chrome_binary, value), do: value in [nil, false] or string?(value)
  defp valid_opt?(:user_data_dir, value), do: is_nil(value) or string?(value)
  defp valid_opt?(:launch_timeout, value), do: is_integer(value) and value >= 0
  defp valid_opt?(:extra_args, value), do: strings?(value)
  defp valid_opt?(:args, value), do: is_nil(value) or strings?(value)

  defp valid_opt?(:window_size, {width, height}),
    do: is_integer(width) and width > 0 and is_integer(height) and height > 0

  defp valid_opt?(:window_size, _value), do: false
  defp valid_opt?(_key, _value), do: true

  defp strings?(value), do: is_list(value) and Enum.all?(value, &string?/1)

  # File, Path and Port.open/2 all take a charlist as readily as a binary.
  defp string?(value), do: is_binary(value) or (is_list(value) and :io_lib.char_list(value))

  defp expected(:headless), do: "a boolean"
  defp expected(:pipe), do: "a boolean; true needs /bin/sh, so not on Windows"
  defp expected(key) when key in [:chrome_binary, :user_data_dir], do: "a string"
  defp expected(:launch_timeout), do: "a non-negative integer"
  defp expected(key) when key in [:extra_args, :args], do: "a list of strings"
  defp expected(:window_size), do: "{width, height} as positive integers"

  @doc false
  @spec default_launch_timeout() :: pos_integer()
  def default_launch_timeout, do: @launch_timeout

  defp do_launch(binary, opts) do
    pipe? = Keyword.get(opts, :pipe, false)
    timeout = Keyword.get(opts, :launch_timeout, @launch_timeout)

    with {:ok, user_data_dir, owns?} <- prepare_user_data_dir(opts),
         {:ok, port} <-
           open_port(binary, build_args(user_data_dir, opts), user_data_dir, owns?, pipe?) do
      await_launch(port, user_data_dir, owns?, pipe?, timeout)
    end
  end

  defp make_profile_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, posix} -> {:error, {:launch_failed, {:user_data_dir, posix}}}
    end
  end

  # Port.open raises (e.g. :eacces, :emfile) rather than returning an error when the
  # spawn itself fails; nothing has started yet, so only the profile dir needs removing.
  # badarg and system_limit arrive as ArgumentError and SystemLimitError, which have no
  # `:original`. badarg is a caller bug that validate_opts!/1 normally stops first, so it
  # keeps raising as a safety net; a full port table is a runtime failure like a refused spawn.
  defp open_port(binary, args, user_data_dir, owns?, pipe?) do
    {executable, argv} = spawn_command(binary, args, pipe?)
    # In pipe mode the Port's stdout is the CDP stream, so stderr must stay out of it.
    output = if pipe?, do: [], else: [:stderr_to_stdout]

    {:ok,
     Port.open(
       {:spawn_executable, executable},
       [:binary, :exit_status, args: argv] ++ output
     )}
  rescue
    error ->
      if owns?, do: remove_dir(user_data_dir)

      case error do
        %SystemLimitError{} -> {:error, {:launch_failed, {:spawn, :system_limit}}}
        %ErlangError{original: reason} -> {:error, {:launch_failed, {:spawn, reason}}}
        _ -> reraise error, __STACKTRACE__
      end
  end

  @doc false
  # The executable and argv the Port spawns for `binary` + `args`: Chrome under the
  # @watchdog script on Unix, Chrome itself on Windows (no /bin/sh there), or Chrome
  # under @pipe_wrapper for `pipe: true` (Unix only, see validate_opts!/1).
  @spec spawn_command(String.t(), [String.t()], boolean()) :: {String.t(), [String.t()]}
  def spawn_command(binary, args, pipe? \\ false)

  def spawn_command(binary, args, true), do: {"/bin/sh", ["-c", @pipe_wrapper, binary | args]}

  def spawn_command(binary, args, false) do
    case :os.type() do
      {:win32, _} -> {binary, args}
      _ -> {"/bin/sh", ["-c", @watchdog, binary | args]}
    end
  end

  defp await_launch(port, user_data_dir, owns?, pipe?, timeout) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    ready =
      if pipe?,
        do: await_pipe(port, deadline(timeout)),
        else: await_debug_url(port, user_data_dir, "", deadline(timeout))

    case ready do
      {:ok, debug_url} ->
        {:ok,
         %{
           port: port,
           os_pid: os_pid,
           debug_url: debug_url,
           pipe: pipe?,
           user_data_dir: user_data_dir,
           owns_data_dir: owns?
         }}

      {:error, reason} ->
        # Align with stop/1: kill -9 is async, so wait for the OS process to exit
        # before removing the temp profile (a still-alive Chrome can recreate files
        # between the rm and the reap), and use remove_dir/1's retry loop.
        kill(os_pid)
        close_port(port)
        await_exit(os_pid, deadline(@stop_exit_timeout))
        if owns?, do: remove_dir(user_data_dir)
        {:error, reason}
    end
  end

  @doc """
  Stops Chrome: kills the OS process, closes the port, and removes the temp
  profile dir (only when `cdp_ex` created it). Idempotent and crash-safe — it is
  the cleanup run from `CDPEx.Browser`'s `terminate/2` callback.
  """
  @spec stop(handle()) :: :ok
  def stop(%{os_pid: os_pid, port: port} = handle) do
    kill(os_pid)
    close_port(port)
    # `kill -9` is asynchronous: it returns before the OS has reaped Chrome, and
    # a still-alive Chrome (or a child) can recreate files in the profile dir
    # right after we delete it — which is exactly how the temp dir "reappeared"
    # and failed cleanup on Linux CI. Wait for the process to actually exit, then
    # remove the dir, retrying until it's gone (covers a child's final flush).
    await_exit(os_pid, deadline(@stop_exit_timeout))
    if Map.get(handle, :owns_data_dir, false), do: remove_dir(handle.user_data_dir)
    :ok
  end

  @doc """
  Resolves the Chrome binary path from (in order) the `:chrome_binary` option,
  the `CDP_EX_CHROME_BINARY` env var, the `CHROME_BINARY` env var, then an
  OS-specific default.
  """
  @spec resolve_binary(keyword()) :: String.t()
  def resolve_binary(opts) do
    opts[:chrome_binary] ||
      System.get_env("CDP_EX_CHROME_BINARY") ||
      System.get_env("CHROME_BINARY") ||
      default_binary()
  end

  @doc """
  Builds the full Chrome argument list for a profile dir.

  Returns `opts[:args]` verbatim when given (full override); otherwise the
  neutral defaults plus `opts[:extra_args]`.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(user_data_dir, opts \\ []) do
    case Keyword.get(opts, :args) do
      nil -> default_args(user_data_dir, opts) ++ Keyword.get(opts, :extra_args, [])
      args when is_list(args) -> args
    end
  end

  @doc """
  The neutral default flag list (stability + headless), with `--user-data-dir`,
  `--window-size`, and the conditional `--headless` applied from `opts`.
  """
  @spec default_args(String.t(), keyword()) :: [String.t()]
  def default_args(user_data_dir, opts \\ []) do
    {width, height} = Keyword.get(opts, :window_size, @default_window_size)
    headless? = Keyword.get(opts, :headless, true)

    base = [
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--disable-setuid-sandbox",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-background-networking",
      "--disable-component-update",
      # Chromium and Chrome for Testing builds apply the bundled field-trial
      # testing config by default, switching on experimental features that keep
      # extra renderer processes alive. Disabling it (Puppeteer and Playwright do
      # too) cut Chrome's peak memory ~30% and raised throughput ~20% with 8
      # concurrent pages, and makes behaviour reproducible across builds.
      "--disable-field-trial-config",
      # Component extensions with a background page each keep an extension process
      # alive that a headless client never uses. Disabling them (Playwright does too)
      # saved one Chrome process and ~13 MB at cold start; throughput under load was
      # unchanged (bench/, docs/TODO.md item 4).
      "--disable-component-extensions-with-background-pages",
      "--window-size=#{width},#{height}",
      "--user-data-dir=#{user_data_dir}",
      debugging_flag(Keyword.get(opts, :pipe, false))
    ]

    headless_flag(headless?) ++ base ++ ["about:blank"]
  end

  defp headless_flag(true), do: ["--headless"]
  defp headless_flag(false), do: []

  defp debugging_flag(true), do: "--remote-debugging-pipe"
  defp debugging_flag(false), do: "--remote-debugging-port=0"

  # ── Chrome discovery ────────────────────────────────────────────────────────

  defp default_binary do
    case :os.type() do
      {:unix, :darwin} ->
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

      {:win32, _} ->
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"

      {:unix, _} ->
        first_existing_linux() || "/usr/bin/google-chrome"
    end
  end

  defp first_existing_linux do
    Enum.find(
      [
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium"
      ],
      &File.exists?/1
    )
  end

  # A bare File.exists? would let a directory or a non-executable file through to
  # Port.open, which raises instead of returning {:error, {:chrome_not_found, _}}.
  # Require a regular file, and on unix the executable bit.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> regular_executable?(stat)
      _ -> false
    end
  end

  defp regular_executable?(stat) do
    case :os.type() do
      # Windows has no unix exec bit; a regular file is enough.
      {:win32, _} -> true
      # Any of user/group/other execute bits (0o111) set.
      _ -> band(stat.mode, 0o111) != 0
    end
  end

  defp prepare_user_data_dir(opts) do
    case {Keyword.get(opts, :user_data_dir), System.tmp_dir()} do
      {nil, nil} ->
        {:error, {:launch_failed, {:user_data_dir, :no_tmp_dir}}}

      {nil, tmp} ->
        :ok = sweep_stale_profile_dirs(tmp)
        create_temp_profile_dir(tmp)

      {dir, _tmp} ->
        with :ok <- make_profile_dir(dir), do: {:ok, dir, false}
    end
  end

  @doc false
  # Creates a fresh profile dir under `tmp` and returns `{:ok, dir, true}`.
  #
  # `System.unique_integer/1` is unique only within one VM, and every VM starts
  # from the same small numbers, so the OS pid goes into the name too: two VMs on
  # one host, or a VM restarted after a crash, must not share a profile. The dir
  # is created with `File.mkdir/1`, not `mkdir_p`, so an existing dir (left by a
  # crashed VM whose OS pid was recycled) is never reused: Chrome would refuse
  # it with a `SingletonLock` error while its old owner still runs, and our
  # `stop/1` would delete a dir that isn't ours. `next_name` is injectable for tests.
  @spec create_temp_profile_dir(String.t(), (-> String.t())) ::
          {:ok, String.t(), true} | {:error, {:launch_failed, {:user_data_dir, term()}}}
  def create_temp_profile_dir(tmp, next_name \\ &temp_profile_name/0),
    do: create_temp_profile_dir(tmp, next_name, @temp_dir_attempts)

  defp create_temp_profile_dir(_tmp, _next_name, 0),
    do: {:error, {:launch_failed, {:user_data_dir, :eexist}}}

  defp create_temp_profile_dir(tmp, next_name, attempts) do
    dir = Path.join(tmp, next_name.())

    case File.mkdir(dir) do
      :ok -> {:ok, dir, true}
      {:error, :eexist} -> create_temp_profile_dir(tmp, next_name, attempts - 1)
      {:error, posix} -> {:error, {:launch_failed, {:user_data_dir, posix}}}
    end
  end

  defp temp_profile_name, do: "cdp_ex-#{System.pid()}-#{System.unique_integer([:positive])}"

  @doc false
  # Removes the temp profile dirs under `tmp` left by VMs that died without running
  # `terminate/2` (`kill -9`, the OOM killer): the watchdog kills their Chrome, but
  # nothing removes the dir. A dir is removed only if its name is exactly
  # `cdp_ex-<os_pid>-<n>` (see temp_profile_name/0), it is a real dir (not a
  # symlink), and `kill -0` says no process `<os_pid>` exists. A live pid, this
  # VM's own, or any doubt (`kill` missing, `EPERM`, Windows) keeps the dir. If the
  # OS has reused a dead VM's pid, its dir is kept too: safe, but incomplete.
  #
  # Best-effort: always returns `:ok`, so a dir that can't be listed or removed
  # never fails the launch.
  @spec sweep_stale_profile_dirs(String.t()) :: :ok
  def sweep_stale_profile_dirs(tmp) do
    _ =
      with false <- match?({:win32, _}, :os.type()),
           {:ok, names} <- File.ls(tmp) do
        own = System.pid()

        names
        |> Enum.flat_map(&stale_candidate(&1, own))
        |> Enum.group_by(fn {pid, _name} -> pid end, fn {_pid, name} -> name end)
        |> Enum.each(fn {pid, pid_names} -> remove_if_gone(tmp, pid, pid_names) end)
      end

    :ok
  rescue
    _ -> :ok
  end

  defp stale_candidate(name, own) do
    case Regex.run(~r/\Acdp_ex-([1-9][0-9]*)-[1-9][0-9]*\z/, name) do
      [_, ^own] -> []
      [_, pid] -> [{pid, name}]
      nil -> []
    end
  end

  defp remove_if_gone(tmp, pid, names) do
    if os_pid_gone?(pid), do: Enum.each(names, &remove_stale_dir(tmp, &1)), else: :ok
  end

  defp remove_stale_dir(tmp, name) do
    dir = Path.join(tmp, name)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = File.rm_rf(dir)
        :ok

      _ ->
        :ok
    end
  end

  # ── DevTools URL discovery ──────────────────────────────────────────────────

  # Chrome prints `DevTools listening on ws://127.0.0.1:<port>/devtools/browser/<uuid>`
  # to stderr, but on some builds/configs (notably new-headless, or under load)
  # that line is slow or never printed. So while waiting we also poll the
  # DevToolsActivePort file every @devtools_poll_interval and return the instant
  # it's readable — making @launch_timeout a ceiling rather than a fixed wait, and
  # readiness detection robust to Chrome variants that don't print the stderr line.
  defp await_debug_url(port, dir, buffer, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      read_devtools_file(dir, buffer)
    else
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          case Regex.run(~r{(ws://[^\s]+/devtools/browser/[0-9a-fA-F-]+)}, buffer) do
            [_, url] -> {:ok, url}
            nil -> await_debug_url(port, dir, buffer, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, exit_reason(status, buffer)}
      after
        # A bounded tick (never past the deadline): try the file, else keep
        # waiting and accumulating stderr. Only the `remaining <= 0` branch above
        # surfaces an error, so a not-yet-written file here just polls again.
        min(@devtools_poll_interval, remaining) ->
          case read_devtools_file(dir, buffer) do
            {:ok, url} -> {:ok, url}
            {:error, _} -> await_debug_url(port, dir, buffer, deadline)
          end
      end
    end
  end

  # Pipe readiness: Chrome reads the pipe only once DevTools is up, so the probe can be
  # written at once and its reply means Chrome is ready. Nothing else arrives before
  # it: Chrome sends events only for domains or targets a client has enabled, and no
  # client has yet. A Port.command on a port that already closed raises; the
  # exit_status it delivered first is still in the mailbox and is read below.
  defp await_pipe(port, deadline) do
    try do
      Port.command(port, Protocol.pipe_frame(@pipe_probe))
    rescue
      ArgumentError -> :ok
    end

    await_pipe_reply(port, "", deadline)
  end

  defp await_pipe_reply(port, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        case Protocol.split_pipe_messages(buffer, data) do
          {[], buffer} -> await_pipe_reply(port, buffer, deadline)
          {[reply | _], _rest} -> pipe_probe_result(reply)
        end

      {^port, {:exit_status, status}} ->
        {:error, exit_reason(status, "")}
    after
      max(remaining_ms(deadline), 0) -> {:error, {:debug_url_not_found, ""}}
    end
  end

  defp pipe_probe_result(reply) do
    case Jason.decode(reply) do
      {:ok, %{"id" => 0, "result" => _}} -> {:ok, nil}
      _ -> {:error, {:debug_url_not_found, String.slice(reply, 0, 500)}}
    end
  end

  # Under the @watchdog script a binary the OS refuses to exec makes /bin/sh exit 126
  # (not executable) or 127 (not found) before Chrome runs. Report that as the spawn
  # failure it is, the same shape Port.open's exception gives a direct spawn.
  defp exit_reason(status, buffer) do
    case {:os.type(), status} do
      {{:unix, _}, 126} -> {:launch_failed, {:spawn, :eacces}}
      {{:unix, _}, 127} -> {:launch_failed, {:spawn, :enoent}}
      _ -> {:chrome_exited, status, String.slice(buffer, 0, 500)}
    end
  end

  # DevToolsActivePort: line 1 is the port, line 2 is the /devtools/browser/<uuid> path.
  # On a missing file, carry the captured stderr excerpt so a launch that never
  # exposed the endpoint is self-diagnosing instead of a context-free atom.
  defp read_devtools_file(dir, buffer) do
    case File.read(Path.join(dir, "DevToolsActivePort")) do
      {:ok, contents} -> parse_devtools_contents(contents)
      {:error, _} -> {:error, {:debug_url_not_found, String.slice(buffer, 0, 500)}}
    end
  end

  # Carry the malformed contents excerpt (mirroring debug_url_not_found's stderr
  # excerpt) so a bad DevToolsActivePort is self-diagnosing, not a context-free atom.
  defp parse_devtools_contents(contents) do
    with [port_str, browser_path | _] <- String.split(String.trim(contents), "\n"),
         {port_num, _} <- Integer.parse(port_str) do
      {:ok, "ws://127.0.0.1:#{port_num}#{browser_path}"}
    else
      _ -> {:error, {:devtools_file_malformed, String.slice(contents, 0, 500)}}
    end
  end

  # ── process control ─────────────────────────────────────────────────────────

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    {cmd, args} =
      case :os.type() do
        {:win32, _} -> {"taskkill", ["/F", "/T", "/PID", to_string(os_pid)]}
        _ -> {"kill", ["-9", to_string(os_pid)]}
      end

    _ = System.cmd(cmd, args, stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp await_exit(nil, _deadline), do: :ok

  defp await_exit(os_pid, deadline) do
    if os_alive?(os_pid) and remaining_ms(deadline) > 0 do
      Process.sleep(20)
      await_exit(os_pid, deadline)
    else
      :ok
    end
  end

  # `kill -0` signals nothing but returns success only if the process exists.
  # On Windows there's no equivalent here, so skip the wait (taskkill /F /T is
  # synchronous enough).
  defp os_alive?(os_pid) do
    case :os.type() do
      {:win32, _} ->
        false

      _ ->
        case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # True only when `kill -0` fails with "No such process" (ESRCH). Unlike
  # os_alive?/1, any other outcome counts as alive: EPERM means the process exists
  # under another user, and a missing `kill` proves nothing. The locale is pinned
  # so the message can be matched.
  defp os_pid_gone?(os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {_, 0} -> false
      {output, _} -> output =~ "No such process"
    end
  rescue
    _ -> false
  end

  # Remove the profile dir, retrying until it's actually gone (a child process
  # can recreate a file between the rm and the check). Best-effort: gives up
  # quietly after a few attempts — it's a temp dir the OS will reclaim anyway.
  defp remove_dir(dir), do: remove_dir(dir, 5)
  defp remove_dir(_dir, 0), do: :ok

  defp remove_dir(dir, attempts) do
    _ = File.rm_rf(dir)

    if File.dir?(dir) do
      Process.sleep(50)
      remove_dir(dir, attempts - 1)
    else
      :ok
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)
end
