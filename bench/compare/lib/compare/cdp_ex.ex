defmodule Compare.CDPEx do
  @moduledoc """
  CDPEx. Two setups (`CDP_EX_SETUP`):

    * `"browser"` (default): one browser; every job opens `new_page(isolated: true)`
      and closes it, so each job gets a fresh context.
    * `"pool"`: `CDPEx.Pool` with one browser per worker and `Pool.with_page/3`, the
      library's documented way to run parallel jobs (a fresh context per job too).
    * `"reuse"`: one browser and one page per worker, opened at start and
      navigated by every job: what ChromicPDF's session pool and a Wallaby
      session do, for a like-for-like row.
  """
  @behaviour Compare.Lib

  alias CDPEx.Page

  @window {1280, 800}

  @impl true
  def name, do: "cdp_ex"

  @impl true
  def version, do: Compare.Lib.dep_version(:cdp_ex)

  def setup, do: System.get_env("CDP_EX_SETUP", "browser")

  @impl true
  def start(opts) do
    launch = [window_size: @window] ++ Keyword.get(opts, :launch, [])

    case setup() do
      "pool" ->
        {:ok, pool} =
          CDPEx.Pool.start_link(size: Keyword.get(opts, :parallel, 1), launch_opts: launch)

        # Launches lazily: warm every browser before timing.
        1..Keyword.get(opts, :parallel, 1)
        |> Task.async_stream(fn _ -> CDPEx.Pool.with_page(pool, fn _ -> :ok end) end,
          max_concurrency: Keyword.get(opts, :parallel, 1)
        )
        |> Stream.run()

        {:pool, pool}

      "browser" ->
        {:ok, browser} = CDPEx.launch(launch)
        {:browser, browser}

      "reuse" ->
        {:ok, browser} = CDPEx.launch(launch)
        pages = for _ <- 1..Keyword.get(opts, :parallel, 1), do: ok!(CDPEx.new_page(browser))
        {:reuse, browser, List.to_tuple(pages)}
    end
  end

  @impl true
  def stop({:pool, pool}), do: CDPEx.Pool.stop(pool)
  def stop({:browser, browser}), do: CDPEx.stop(browser)
  def stop({:reuse, browser, _}), do: CDPEx.stop(browser)

  defp with_page({:pool, pool}, fun), do: CDPEx.Pool.with_page(pool, fun)
  defp with_page({:reuse, _, pages}, fun), do: fun.(elem(pages, Process.get(:worker, 0)))

  defp with_page({:browser, browser}, fun) do
    page = ok!(CDPEx.new_page(browser, isolated: true))

    try do
      fun.(page)
    after
      CDPEx.close_page(browser, page)
    end
  end

  defp open(page, url, ready) do
    # The same 1280x800 viewport as the others; the window size alone leaves
    # less than 800 px to the page in headless Chrome.
    :ok = Page.set_viewport(page, 1280, 800)
    ok!(Page.navigate(page, url, wait_until: :load))

    case ready do
      :load -> :ok
      {:css, css} -> :ok = Page.wait_for_selector(page, css)
    end
  end

  @impl true
  def screenshot(st, w, url, ready) do
    Process.put(:worker, w)

    with_page(st, fn page ->
      open(page, url, ready)
      Page.screenshot(page)
    end)
    |> wrap()
  end

  @impl true
  def pdf(st, w, url, ready) do
    Process.put(:worker, w)

    with_page(st, fn page ->
      open(page, url, ready)
      Page.pdf(page)
    end)
    |> wrap()
  end

  @impl true
  def text(st, w, url, ready, css) do
    Process.put(:worker, w)

    with_page(st, fn page ->
      open(page, url, ready)
      Page.text(page, css)
    end)
    |> wrap()
  end

  @impl true
  def click(st, w, url, ready, click, after_css) do
    Process.put(:worker, w)

    with_page(st, fn page ->
      open(page, url, ready)
      :ok = Page.click(page, click)
      :ok = Page.wait_for_selector(page, after_css)
      Page.text(page, after_css)
    end)
    |> wrap()
  end

  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap(other), do: raise("unexpected: #{inspect(other)}")

  defp ok!({:ok, value}), do: value
  defp ok!({:ok, value, _}), do: value
  defp ok!(:ok), do: :ok
  defp ok!(other), do: raise("unexpected: #{inspect(other)}")

  @raw "no function in CDPEx's API; only by sending raw CDP through CDPEx.Connection.call/5"

  @impl true
  def probes(st, fx) do
    probe = fn fun -> fn -> with_page(st, &{:ok, fun.(&1)}) end end
    url = fx.base <> "/probe/"

    [
      evaluate:
        probe.(fn page ->
          open(page, url, :load)
          ok!(Page.evaluate(page, "1 + 2"))
        end),
      fill_form:
        probe.(fn page ->
          open(page, url, :load)
          :ok = Page.type(page, "#name", "Alice")
          # No select/check helpers: set them from JS.
          ok!(Page.evaluate(page, "document.querySelector('#color').value = 'green'"))
          :ok = Page.click(page, "#agree")
          ok!(Page.evaluate(page, "[name.value, color.value, agree.checked].join(',')"))
        end),
      wait_selector:
        probe.(fn page ->
          open(page, fx.base <> "/js/", :load)
          :ok = Page.wait_for_selector(page, ".article-preview")
          "waited"
        end),
      wait_js:
        probe.(fn page ->
          open(page, fx.base <> "/js/", :load)

          :ok =
            Page.wait_for_function(
              page,
              "document.querySelectorAll('.article-preview').length === 20"
            )

          "waited"
        end),
      wait_network_idle:
        probe.(fn page ->
          ok!(Page.navigate(page, fx.base <> "/js/", wait_until: :none))
          :ok = Page.wait_for_network_idle(page)
          "idle"
        end),
      wait_response_body:
        probe.(fn page ->
          {:ok, %{"body" => body}} =
            Page.wait_for_response(page, "/api/articles?",
              trigger: fn -> Page.navigate(page, fx.base <> "/js/", wait_until: :none) end,
              body: true
            )

          byte_size(body)
        end),
      cookies:
        probe.(fn page ->
          open(page, url, :load)
          :ok = Page.set_cookies(page, [%{name: "probe", value: "1", url: url}])
          page |> Page.cookies() |> ok!() |> Enum.map(& &1["name"])
        end),
      interception:
        probe.(fn page ->
          :ok =
            Page.enable_request_interception(page,
              patterns: [%{"urlPattern" => "*/probe/file.txt"}]
            )

          task =
            Task.async(fn ->
              Page.navigate(page, fx.base <> "/probe/file.txt", wait_until: :load)
            end)

          receive do
            {:cdp_event, _, "Fetch.requestPaused", %{"requestId" => id}, _} ->
              :ok =
                Page.fulfill_request(page, id,
                  status: 200,
                  body: "rewritten",
                  headers: %{"content-type" => "text/plain"}
                )
          after
            10_000 -> raise "no paused request"
          end

          Task.await(task)
          ok!(Page.evaluate(page, "document.body.innerText"))
        end),
      block_by_type: fn -> block_probe(st, fx, fx.base <> "/html/", "site.test") end,
      cross_site_block: fn -> block_probe(st, fx, fx.base <> "/heavy/", "embed.test") end,
      site_login:
        probe.(fn page ->
          :ok = Page.authenticate(page, "user", "pass")
          open(page, fx.base <> "/auth/", :load)
          ok!(Page.text(page, "#ok"))
        end),
      proxy_auth: fn -> proxy_probe(fx) end,
      isolation: fn -> isolation_probe(st, fx) end,
      pool: fn ->
        {:ok, pool} = CDPEx.Pool.start_link(size: 2, launch_opts: [window_size: @window])

        try do
          results =
            1..2
            |> Task.async_stream(fn _ -> CDPEx.Pool.with_page(pool, &Page.evaluate(&1, "1")) end)
            |> Enum.map(fn {:ok, {:ok, v}} -> v end)

          {:ok, "#{length(results)} jobs on CDPEx.Pool"}
        after
          CDPEx.Pool.stop(pool)
        end
      end,
      attach: fn -> Compare.Probe.with_debug_chrome(fn %{ws: ws} -> attach_probe(ws, fx) end) end,
      telemetry: fn ->
        Compare.Probe.telemetry(:cdp_ex, fn -> screenshot(st, 0, fx.base <> "/html/", :load) end)
      end,
      viewport_ua:
        probe.(fn page ->
          :ok = Page.set_user_agent(page, "probe-agent")
          open(page, url, :load)
          :ok = Page.set_viewport(page, 400, 300)
          ok!(Page.evaluate(page, "innerWidth + 'x' + innerHeight + ' ' + navigator.userAgent"))
        end),
      pdf_a: fn ->
        {:unsupported, "no PDF/A option on Page.pdf/2 (landscape, print_background, path)"}
      end,
      pdf_header_footer: fn ->
        {:unsupported, "Page.pdf/2 has no header/footer template options"}
      end,
      html_string_pdf: fn ->
        {:unsupported, "no API to load an HTML string; navigate/3 takes a URL (a data: URL works)"}
      end,
      file_upload:
        probe.(fn page ->
          open(page, url, :load)
          path = Path.join(System.tmp_dir!(), "upload.txt")
          File.write!(path, "x")
          :ok = Page.set_input_files(page, "#file", path)
          ok!(Page.text(page, "#fileName"))
        end),
      download: fn -> {:unsupported, @raw <> " (Browser.setDownloadBehavior)"} end,
      dialog:
        probe.(fn page ->
          open(page, url, :load)
          :ok = Page.click(page, "#alert")
          ok!(Page.text(page, "#dialog"))
        end),
      hover:
        probe.(fn page ->
          open(page, url, :load)
          :ok = Page.hover(page, "#hover")
          ok!(Page.text(page, "#hover"))
        end),
      console: fn -> {:unsupported, @raw <> " (Runtime.consoleAPICalled)"} end,
      iframe_content: fn ->
        {:unsupported, "Page functions run in the main frame only; no frame selection"}
      end,
      timezone: fn -> {:unsupported, @raw <> " (Emulation.setTimezoneOverride)"} end,
      clock: fn -> {:unsupported, "no clock control"} end,
      tracing: fn -> {:unsupported, "no tracing API"} end,
      firefox: fn -> {:unsupported, "drives Chrome / Chromium over CDP only"} end,
      webkit: fn -> {:unsupported, "drives Chrome / Chromium over CDP only"} end
    ]
  end

  defp block_probe(st, fx, url, host) do
    Compare.Fixture.reset_log(fx)

    with_page_opts(st, [block: [:image]], fn page ->
      ok!(Page.navigate(page, url, wait_until: :load))
    end)

    log = Compare.Fixture.log(fx)
    pages = Enum.count(log, &(&1["host"] == host and not String.starts_with?(&1["path"], "/img/")))
    images = Enum.count(log, &(&1["host"] == host and String.starts_with?(&1["path"], "/img/")))
    Compare.Probe.blocked(host, pages, images)
  end

  defp with_page_opts({:browser, browser}, opts, fun) do
    page = ok!(CDPEx.new_page(browser, [isolated: true] ++ opts))

    try do
      fun.(page)
    after
      CDPEx.close_page(browser, page)
    end
  end

  defp with_page_opts(st, _opts, fun), do: with_page(st, fun)

  defp proxy_probe(fx) do
    Compare.Fixture.reset_log(fx)

    {:ok, browser} =
      CDPEx.launch(
        window_size: @window,
        proxy: "http://user:pass@" <> URI.parse(fx.proxy).authority
      )

    try do
      page = ok!(CDPEx.new_page(browser))
      ok!(Page.navigate(page, fx.base <> "/heavy/", wait_until: :load))
      Compare.Probe.proxied(Compare.Fixture.log(fx))
    after
      CDPEx.stop(browser)
    end
  end

  defp isolation_probe(st, fx) do
    url = fx.base <> "/probe/"

    with_page(st, fn page ->
      open(page, url, :load)
      :ok = Page.set_cookies(page, [%{name: "a", value: "1", url: url}])
    end)

    with_page(st, fn page ->
      open(page, url, :load)
      Compare.Probe.isolated(page |> Page.cookies() |> ok!() |> Enum.map(& &1["name"]))
    end)
  end

  defp attach_probe(ws, fx) do
    {:ok, browser} = CDPEx.connect(ws)

    try do
      page = ok!(CDPEx.new_page(browser))
      ok!(Page.navigate(page, fx.base <> "/probe/", wait_until: :load))
      {:ok, ok!(Page.text(page, "#title"))}
    after
      CDPEx.stop(browser)
    end
  end
end
