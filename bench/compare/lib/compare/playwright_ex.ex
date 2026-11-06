defmodule Compare.PlaywrightEx do
  @moduledoc """
  playwright_ex: the Playwright Node.js driver (`playwright run-driver`), pointed at
  the shared Chromium. One browser; every job opens a new context and page and
  closes the context, the README's pattern.
  """
  @behaviour Compare.Lib

  alias PlaywrightEx.{Browser, BrowserContext, EventWaiter, Frame, Page, Route}

  @t 30_000
  @viewport %{width: 1280, height: 800}

  @impl true
  def name, do: "playwright_ex"

  @impl true
  def version, do: Compare.Lib.dep_version(:playwright_ex)

  @impl true
  def start(opts) do
    {:ok, sup} = PlaywrightEx.Supervisor.start_link(timeout: @t, executable: "playwright")
    Process.unlink(sup)

    {:ok, browser} =
      PlaywrightEx.launch_browser(
        :chromium,
        [timeout: @t, executable_path: System.fetch_env!("CHROME"), headless: true] ++
          Keyword.get(opts, :launch, [])
      )

    %{sup: sup, browser: browser.guid}
  end

  @impl true
  def stop(%{sup: sup, browser: browser}) do
    _ = Browser.close(browser, timeout: @t)
    ref = Process.monitor(sup)
    Process.exit(sup, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp with_page(%{browser: browser}, fun, ctx_opts \\ []) do
    {:ok, ctx} =
      Browser.new_context(browser, Keyword.merge([timeout: @t, viewport: @viewport], ctx_opts))

    try do
      {:ok, page} = BrowserContext.new_page(ctx.guid, timeout: @t)
      fun.(%{page: page.guid, frame: page.main_frame.guid, ctx: ctx.guid})
    after
      BrowserContext.close(ctx.guid, timeout: @t)
    end
  end

  defp open(%{frame: frame}, url, ready) do
    {:ok, _} = Frame.goto(frame, url: url, wait_until: "load", timeout: @t)

    case ready do
      :load ->
        :ok

      {:css, css} ->
        {:ok, _} = Frame.wait_for_selector(frame, selector: css, strict: false, timeout: @t)
    end
  end

  @impl true
  def screenshot(st, _w, url, ready) do
    with_page(st, fn p ->
      open(p, url, ready)
      {:ok, png} = Page.screenshot(p.page, timeout: @t)
      {:ok, Base.decode64!(png)}
    end)
  end

  @pdf_how "no function in playwright_ex; raw protocol message `pdf` via PlaywrightEx.send/2"

  @impl true
  def pdf(st, _w, url, ready) do
    with_page(st, fn p ->
      open(p, url, ready)

      case PlaywrightEx.send(%{guid: p.page, method: :pdf, params: %{}}, timeout: @t) do
        %{result: %{pdf: data}} -> {:partial, @pdf_how, Base.decode64!(data)}
        other -> raise "pdf: #{inspect(other)}"
      end
    end)
  end

  @impl true
  def text(st, _w, url, ready, css) do
    with_page(st, fn p ->
      open(p, url, ready)
      {:ok, text} = Frame.inner_text(p.frame, selector: css, strict: false, timeout: @t)
      {:ok, text}
    end)
  end

  @impl true
  def click(st, _w, url, ready, click, after_css) do
    with_page(st, fn p ->
      open(p, url, ready)
      {:ok, _} = Frame.click(p.frame, selector: click <> " >> nth=0", timeout: @t)
      {:ok, _} = Frame.wait_for_selector(p.frame, selector: after_css, timeout: @t)
      {:ok, text} = Frame.inner_text(p.frame, selector: after_css, timeout: @t)
      {:ok, text}
    end)
  end

  @impl true
  def probes(st, fx) do
    url = fx.base <> "/probe/"
    probe = fn fun, ctx_opts -> fn -> with_page(st, &{:ok, fun.(&1)}, ctx_opts) end end
    p = fn fun -> probe.(fun, []) end

    [
      evaluate:
        p.(fn pg ->
          open(pg, url, :load)
          {:ok, v} = Frame.evaluate(pg.frame, expression: "1 + 2", timeout: @t)
          v
        end),
      fill_form:
        p.(fn pg ->
          open(pg, url, :load)
          {:ok, _} = Frame.fill(pg.frame, selector: "#name", value: "Alice", timeout: @t)

          {:ok, _} =
            Frame.select_option(pg.frame,
              selector: "#color",
              options: [%{value: "green"}],
              timeout: @t
            )

          {:ok, _} = Frame.check(pg.frame, selector: "#agree", timeout: @t)

          {:ok, v} =
            Frame.evaluate(pg.frame,
              expression: "[name.value, color.value, agree.checked].join(',')",
              timeout: @t
            )

          v
        end),
      file_upload:
        p.(fn pg ->
          open(pg, url, :load)
          path = Path.join(System.tmp_dir!(), "upload.txt")
          File.write!(path, "x")

          {:ok, _} =
            Frame.set_input_files(pg.frame, selector: "#file", local_paths: [path], timeout: @t)

          {:ok, name} = Frame.inner_text(pg.frame, selector: "#fileName", timeout: @t)
          name
        end),
      download:
        probe.(
          fn pg ->
            open(pg, url, :load)
            {:ok, pending} = Page.expect_download(pg.page, timeout: @t)
            {:ok, _} = Frame.click(pg.frame, selector: "#download", timeout: @t)

            try do
              {:ok, download} = Page.await_download(pending)
              dest = Path.join(System.tmp_dir!(), "pw-download.txt")
              :ok = PlaywrightEx.Download.save_as(download, dest, timeout: @t)
              File.read!(dest)
            rescue
              e in FunctionClauseError ->
                throw(
                  {:fail,
                   "the documented expect_download/await_download flow raised in the library: " <>
                     Exception.message(e)}
                )
            end
          end,
          accept_downloads: true
        ),
      dialog:
        p.(fn pg ->
          open(pg, url, :load)
          # Dialog events come on the context's channel.
          {:ok, waiter} = EventWaiter.arm(pg.ctx, :dialog, timeout: @t)
          task = Task.async(fn -> Frame.click(pg.frame, selector: "#alert", timeout: @t) end)
          {:ok, event} = EventWaiter.await(waiter)
          {:ok, _} = PlaywrightEx.Dialog.accept(event.params.dialog.guid, timeout: @t)
          Task.await(task)
          {:ok, v} = Frame.inner_text(pg.frame, selector: "#dialog", timeout: @t)
          v
        end),
      hover:
        p.(fn pg ->
          open(pg, url, :load)
          {:ok, _} = Frame.hover(pg.frame, selector: "#hover", timeout: @t)
          {:ok, v} = Frame.inner_text(pg.frame, selector: "#hover", timeout: @t)
          v
        end),
      iframe_content:
        p.(fn pg ->
          open(pg, url, :load)
          sel = "#embed >> internal:control=enter-frame >> #inside"
          {:ok, v} = Frame.inner_text(pg.frame, selector: sel, timeout: @t)
          v
        end),
      wait_selector:
        p.(fn pg ->
          open(pg, fx.base <> "/js/", {:css, ".article-preview"})
          "waited"
        end),
      wait_js:
        p.(fn pg ->
          open(pg, fx.base <> "/js/", :load)

          {:ok, _} =
            Frame.wait_for_function(pg.frame,
              expression: "() => document.querySelectorAll('.article-preview').length === 20",
              timeout: @t
            )

          "waited"
        end),
      wait_network_idle:
        p.(fn pg ->
          {:ok, _} =
            Frame.goto(pg.frame, url: fx.base <> "/js/", wait_until: "networkidle", timeout: @t)

          "idle"
        end),
      cookies:
        p.(fn pg ->
          open(pg, url, :load)

          {:ok, _} =
            BrowserContext.add_cookies(pg.ctx,
              cookies: [%{name: "probe", value: "1", url: url}],
              timeout: @t
            )

          {:ok, cookies} = BrowserContext.cookies(pg.ctx, timeout: @t)
          Enum.map(cookies, & &1.name)
        end),
      interception:
        p.(fn pg ->
          :ok =
            ok_or(
              Page.route(
                pg.page,
                "**/probe/file.txt",
                fn route, _request ->
                  {:ok, _} = Route.fulfill(route, body: "rewritten", content_type: "text/plain")
                end, timeout: @t)
            )

          {:ok, _} = Frame.goto(pg.frame, url: fx.base <> "/probe/file.txt", timeout: @t)
          {:ok, v} = Frame.evaluate(pg.frame, expression: "document.body.innerText", timeout: @t)
          v
        end),
      block_by_type: fn -> block_probe(st, fx, fx.base <> "/html/", "site.test") end,
      cross_site_block: fn -> block_probe(st, fx, fx.base <> "/heavy/", "embed.test") end,
      site_login:
        probe.(
          fn pg ->
            open(pg, fx.base <> "/auth/", :load)
            {:ok, v} = Frame.inner_text(pg.frame, selector: "#ok", timeout: @t)
            v
          end,
          http_credentials: %{username: "user", password: "pass"}
        ),
      proxy_auth: fn -> proxy_probe(fx) end,
      isolation: fn ->
        with_page(st, fn pg ->
          open(pg, url, :load)

          {:ok, _} =
            BrowserContext.add_cookies(pg.ctx,
              cookies: [%{name: "a", value: "1", url: url}],
              timeout: @t
            )
        end)

        with_page(st, fn pg ->
          open(pg, url, :load)
          {:ok, cookies} = BrowserContext.cookies(pg.ctx, timeout: @t)
          Compare.Probe.isolated(Enum.map(cookies, & &1.name))
        end)
      end,
      viewport_ua:
        probe.(
          fn pg ->
            open(pg, url, :load)

            {:ok, v} =
              Frame.evaluate(pg.frame,
                expression: "innerWidth + 'x' + innerHeight + ' ' + navigator.userAgent",
                timeout: @t
              )

            v
          end,
          viewport: %{width: 400, height: 300},
          user_agent: "probe-agent"
        ),
      timezone:
        probe.(
          fn pg ->
            open(pg, url, :load)

            {:ok, v} =
              Frame.evaluate(pg.frame,
                expression: "Intl.DateTimeFormat().resolvedOptions().timeZone",
                timeout: @t
              )

            v
          end,
          timezone_id: "Asia/Tokyo"
        ),
      clock:
        p.(fn pg ->
          {:ok, _} = BrowserContext.clock_install(pg.ctx, time: 0, timeout: @t)
          open(pg, url, :load)
          {:ok, v} = Frame.inner_text(pg.frame, selector: "#time", timeout: @t)
          v
        end),
      console:
        p.(fn pg ->
          {:ok, waiter} = EventWaiter.arm(pg.ctx, :console, timeout: @t)
          open(pg, url, :load)
          {:ok, event} = EventWaiter.await(waiter)

          event.params
          |> inspect()
          |> String.contains?("probe-console")
          |> if(
            do: "console event: probe-console",
            else: raise("other console event: #{inspect(event.params)}")
          )
        end),
      wait_response_body: fn ->
        {:unsupported,
         "response events and Request.response/2 give metadata only; no response body function"}
      end,
      tracing:
        p.(fn pg ->
          conn = PlaywrightEx.Supervisor.Connection
          %{tracing: %{guid: tracing}} = PlaywrightEx.Connection.initializer!(conn, pg.ctx)

          {:ok, _} =
            PlaywrightEx.Tracing.tracing_start(tracing,
              screenshots: true,
              snapshots: true,
              timeout: @t
            )

          open(pg, url, :load)
          {:ok, stopped} = PlaywrightEx.Tracing.tracing_stop(tracing, timeout: @t)
          "tracing_start / tracing_stop: #{inspect(stopped, limit: 3)}"
        end),
      telemetry: fn ->
        Compare.Probe.telemetry(:playwright_ex, fn ->
          screenshot(st, 0, fx.base <> "/html/", :load)
        end)
      end,
      firefox: fn ->
        {:unsupported, "needs Playwright's Firefox build; probed in the browsers run"}
      end,
      webkit: fn ->
        {:unsupported, "needs Playwright's WebKit build; probed in the browsers run"}
      end,
      pool: fn -> {:unsupported, "no pool of browsers or pages in the API"} end,
      attach: fn ->
        {:unsupported,
         "connects to a remote Playwright server (ws_endpoint), not to a running Chrome; no connect_over_cdp"}
      end,
      pdf_a: fn -> {:unsupported, "no PDF API at all (see pdf); no PDF/A"} end,
      pdf_header_footer: fn ->
        {:unsupported, "no PDF API (Playwright's page.pdf header/footer options aren't wrapped)"}
      end,
      html_string_pdf: fn -> {:unsupported, "no PDF API"} end
    ]
  end

  @doc "Firefox and WebKit, in the probe-only browsers image (Playwright's own builds)."
  def browser_probes(fx) do
    {:ok, sup} = PlaywrightEx.Supervisor.start_link(timeout: @t, executable: "playwright")
    Process.unlink(sup)

    for type <- [:firefox, :webkit] do
      {type,
       fn ->
         {:ok, browser} = PlaywrightEx.launch_browser(type, timeout: @t, headless: true)

         try do
           with_page(%{browser: browser.guid}, fn pg ->
             open(pg, fx.base <> "/probe/", :load)
             {:ok, text} = Frame.inner_text(pg.frame, selector: "#title", timeout: @t)
             {:ok, "#{type}: read #{inspect(text)}"}
           end)
         after
           Browser.close(browser.guid, timeout: @t)
         end
       end}
    end
  end

  defp ok_or(:ok), do: :ok
  defp ok_or({:ok, _}), do: :ok
  defp ok_or(other), do: raise("unexpected: #{inspect(other)}")

  defp block_probe(st, fx, url, host) do
    Compare.Fixture.reset_log(fx)

    with_page(st, fn pg ->
      :ok =
        ok_or(
          BrowserContext.route(
            pg.ctx,
            "**/*",
            fn route, request ->
              if request.resource_type == "image",
                do: {:ok, _} = Route.abort(route),
                else: {:ok, _} = Route.continue(route)
            end, timeout: @t)
        )

      open(pg, url, :load)
    end)

    log = Compare.Fixture.log(fx)
    pages = Enum.count(log, &(&1["host"] == host and not String.starts_with?(&1["path"], "/img/")))
    images = Enum.count(log, &(&1["host"] == host and String.starts_with?(&1["path"], "/img/")))

    case Compare.Probe.blocked(host, pages, images) do
      {:ok, ev} -> {:partial, "no block-by-type option; a route/4 handler that aborts images", ev}
      other -> other
    end
  end

  defp proxy_probe(fx) do
    Compare.Fixture.reset_log(fx)
    proxy = %{server: fx.proxy, username: "user", password: "pass"}

    {:ok, browser} =
      PlaywrightEx.launch_browser(:chromium,
        timeout: @t,
        executable_path: System.fetch_env!("CHROME"),
        headless: true,
        proxy: proxy
      )

    try do
      with_page(%{browser: browser.guid}, fn pg -> open(pg, fx.base <> "/heavy/", :load) end)
      Compare.Probe.proxied(Compare.Fixture.log(fx))
    after
      Browser.close(browser.guid, timeout: @t)
    end
  end
end
