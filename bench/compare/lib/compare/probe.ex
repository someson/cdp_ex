defmodule Compare.Probe do
  @moduledoc """
  Runs every capability probe for one library and writes the results. Each result
  is one of `ok` (✓), `partial` (done only by a workaround, which it names),
  `unsupported` (✗: no way in the public API; it says what was looked for),
  `fail` (the API exists but the check failed) or `error` (the probe crashed;
  needs a look, never reported as ✗).
  """

  alias Compare.{Check, Fixture}

  # The order is the report's row order.
  @capabilities [
    screenshot: "Screenshot",
    pdf: "PDF",
    pdf_a: "PDF/A",
    pdf_header_footer: "PDF header / footer",
    html_string_pdf: "PDF from an HTML string",
    read_text: "Read an element's text",
    click: "Click",
    fill_form: "Fill a form (type, select, check)",
    file_upload: "File upload",
    download: "Download",
    dialog: "Answer a JS dialog",
    hover: "Hover",
    evaluate: "Evaluate JS, get the value",
    console: "Console messages",
    iframe_content: "Read inside an iframe",
    wait_selector: "Wait for a selector",
    wait_js: "Wait for a JS predicate",
    wait_network_idle: "Wait for network idle",
    wait_response_body: "Wait for a response, with its body",
    cookies: "Set / read cookies",
    interception: "Request interception (fulfill)",
    block_by_type: "Block resources by type",
    cross_site_block: "Block inside a cross-site iframe",
    site_login: "HTTP auth (site login)",
    proxy_auth: "Proxy with credentials",
    isolation: "Per-job isolation",
    pool: "Pool of warm sessions",
    attach: "Attach to a running Chrome",
    telemetry: ":telemetry events",
    viewport_ua: "Viewport and user agent",
    timezone: "Timezone",
    clock: "Clock control",
    tracing: "Tracing",
    firefox: "Firefox",
    webkit: "WebKit"
  ]

  def capabilities, do: @capabilities

  @doc "Firefox / WebKit rows only, for the libraries that can drive them."
  def run_browsers(lib, fx) do
    probes = if function_exported?(lib, :browser_probes, 1), do: lib.browser_probes(fx), else: []

    for {key, fun} <- probes do
      {kind, note} = classify(guard(fun))
      IO.puts(:stderr, "#{lib.name()} #{key}: #{kind} #{note}")

      %{
        lib: lib.name(),
        version: lib.version(),
        key: key,
        label: Keyword.fetch!(@capabilities, key),
        result: kind,
        note: note
      }
    end
  end

  def run(lib, fx) do
    state = lib.start(parallel: 1)

    try do
      timed = timed_probes(lib, state, fx)
      extra = lib.probes(state, fx)

      for {key, label} <- @capabilities do
        fun = Keyword.get(timed, key) || Keyword.get(extra, key)
        {kind, note} = if fun, do: classify(guard(fun)), else: {"not probed", "no probe written"}
        IO.puts(:stderr, "#{lib.name()} #{key}: #{kind} #{note}")
        %{lib: lib.name(), version: lib.version(), key: key, label: label, result: kind, note: note}
      end
    after
      lib.stop(state)
    end
  end

  defp timed_probes(lib, st, fx) do
    html = Fixture.url(fx, "html")
    js = Fixture.page("js")

    [
      screenshot: fn -> lib.screenshot(st, 0, html, :load) |> check(&Check.png(&1, {1280, 800})) end,
      pdf: fn -> lib.pdf(st, 0, html, :load) |> check(&Check.pdf/1) end,
      read_text: fn ->
        lib.text(st, 0, Fixture.url(fx, "js"), js.ready, js.text)
        |> check(&expect(&1, js.expect))
      end,
      click: fn ->
        lib.click(
          st,
          0,
          Fixture.url(fx, "js"),
          js.ready,
          Fixture.click_target(),
          Fixture.after_click()
        )
        |> check(&expect(&1, "How to"))
      end
    ]
  end

  defp expect(text, prefix) do
    if is_binary(text) and String.contains?(text, prefix),
      do: {:ok, "got #{inspect(String.slice(text, 0, 40))}"},
      else: {:fail, "got #{inspect(text)}"}
  end

  defp check({:ok, v}, fun), do: fun.(v)

  defp check({:partial, how, v}, fun) do
    case fun.(v) do
      {:ok, ev} -> {:partial, how, ev}
      other -> other
    end
  end

  defp check(other, _), do: other

  # Expected values for the extra probes; anything else they return is shown as is.
  defp guard(fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 600)}
        catch
          {:fail, why} -> {:fail, why}
          kind, reason -> {:error, "#{kind}: #{inspect(reason) |> String.slice(0, 400)}"}
        end
      end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "timed out after 60 s"}
    end
  end

  defp classify({:ok, ev}), do: {"ok", evidence(ev)}
  defp classify({:partial, how, ev}), do: {"partial", "#{how}; #{evidence(ev)}"}
  defp classify({:unsupported, why}), do: {"unsupported", why}
  defp classify({:fail, why}), do: {"fail", why}
  defp classify({:error, why}), do: {"error", why}

  defp classify(other),
    do: {"error", "unexpected probe result #{inspect(other) |> String.slice(0, 200)}"}

  defp evidence(ev) when is_binary(ev), do: String.slice(ev, 0, 200)
  defp evidence(ev), do: inspect(ev, limit: 10) |> String.slice(0, 200)

  # --- helpers used by the adapters' probes -------------------------------

  def blocked(host, pages, images) do
    cond do
      pages == 0 -> {:fail, "no page from #{host} was loaded, so nothing was tested"}
      images == 0 -> {:ok, "#{pages} page(s) from #{host}, 0 images requested"}
      true -> {:fail, "#{images} images from #{host} still requested"}
    end
  end

  def proxied(log) do
    direct = Enum.reject(log, & &1["proxied"])

    cond do
      log == [] -> {:fail, "no request reached the fixture"}
      direct == [] -> {:ok, "all #{length(log)} requests through the proxy, embed.test included"}
      true -> {:fail, "#{length(direct)} of #{length(log)} requests bypassed the proxy"}
    end
  end

  def isolated(names) do
    if "a" in names,
      do: {:fail, "the next job saw the previous job's cookie"},
      else: {:ok, "the next job didn't see the previous job's cookie"}
  end

  @doc "Runs `fun`, counting `:telemetry` events whose name starts with `prefix`."
  def telemetry(prefix, fun) do
    parent = self()
    :erlang.trace_pattern({:telemetry, :execute, 3}, true, [:global])
    tracer = spawn(fn -> collect(parent, []) end)
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    try do
      _ = fun.()
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({:telemetry, :execute, 3}, false, [:global])
    end

    send(tracer, {:done, self()})

    events =
      receive do
        {:events, events} -> events
      after
        5_000 -> []
      end

    ours = events |> Enum.filter(&match?([^prefix | _], &1)) |> Enum.uniq()

    if ours == [],
      do:
        {:unsupported,
         "no :telemetry.execute/3 call with a [#{inspect(prefix)} | _] name during a job (traced)"},
      else: {:ok, ours |> Enum.take(4) |> Enum.map_join(", ", &inspect/1)}
  end

  defp collect(parent, acc) do
    receive do
      {:trace, _pid, :call, {:telemetry, :execute, [name | _]}} -> collect(parent, [name | acc])
      {:done, from} -> send(from, {:events, Enum.reverse(acc)})
    end
  end

  @doc "Starts a Chrome with a DevTools port outside any library; passes %{ws:, port:}."
  def with_debug_chrome(fun) do
    port = 9333
    dir = Path.join(System.tmp_dir!(), "debug-chrome-#{System.unique_integer([:positive])}")

    chrome =
      Port.open({:spawn_executable, System.fetch_env!("CHROME")}, [
        :binary,
        :exit_status,
        args: [
          "--headless",
          "--no-sandbox",
          "--remote-debugging-port=#{port}",
          "--user-data-dir=#{dir}",
          "about:blank"
        ]
      ])

    {:os_pid, os_pid} = Port.info(chrome, :os_pid)

    try do
      ws = wait_ws(port, 50)
      fun.(%{ws: ws, port: port})
    after
      System.cmd("kill", ["#{os_pid}"])
      File.rm_rf(dir)
    end
  end

  defp wait_ws(_port, 0), do: raise("debug Chrome didn't come up")

  defp wait_ws(port, n) do
    case :httpc.request(~c"http://127.0.0.1:#{port}/json/version") do
      {:ok, {{_, 200, _}, _, body}} ->
        body |> IO.iodata_to_binary() |> Jason.decode!() |> Map.fetch!("webSocketDebuggerUrl")

      _ ->
        Process.sleep(100)
        wait_ws(port, n - 1)
    end
  end
end
