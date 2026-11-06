defmodule Compare.Wallaby do
  @moduledoc """
  Wallaby with its Chrome driver: ChromeDriver from Debian, started by the Wallaby
  application; one `Wallaby.start_session/1` (one Chrome) per worker, reused from
  job to job the way a test reuses its session. Its default capabilities set a
  1280x800 headless window.
  """
  @behaviour Compare.Lib

  alias Wallaby.{Browser, Element, Query}

  @impl true
  def name, do: "wallaby"

  @impl true
  def version, do: Compare.Lib.dep_version(:wallaby)

  @impl true
  def start(opts) do
    Application.put_env(:wallaby, :js_logger, nil)
    Application.put_env(:wallaby, :js_errors, false)
    {:ok, _} = Application.ensure_all_started(:wallaby)

    sessions =
      for _ <- 1..Keyword.get(opts, :parallel, 1) do
        {:ok, session} = Wallaby.start_session()
        fit_viewport(session)
      end

    List.to_tuple(sessions)
  end

  @impl true
  def stop(sessions) do
    sessions |> Tuple.to_list() |> Enum.each(&Wallaby.end_session/1)
    :ok = Application.stop(:wallaby)
  end

  defp session(sessions, w), do: elem(sessions, w)

  # The same 1280x800 viewport as the others: resize the window by what its
  # frame takes (resize_window/3 sets the outer size).
  defp fit_viewport(s) do
    s = Browser.visit(s, Compare.Fixture.from_env().base <> "/")
    {w, h} = js(s, "return [innerWidth, innerHeight]") |> List.to_tuple()
    %{"width" => ow, "height" => oh} = Browser.window_size(s)
    Browser.resize_window(s, ow + 1280 - w, oh + 800 - h)
  end

  defp js(s, script) do
    Browser.execute_script(s, script, [], fn v -> send(self(), {:js, v}) end)

    receive do
      {:js, v} -> v
    after
      5_000 -> raise "no script result"
    end
  end

  defp open(s, url, ready) do
    s = Browser.visit(s, url)

    case ready do
      :load -> s
      {:css, css} -> first(s, css) && s
    end
  end

  # find/2 waits until the query matches; minimum: 1 because the lists have many.
  defp first(s, css) do
    case Browser.find(s, Query.css(css, minimum: 1)) do
      [el | _] -> el
      %Element{} = el -> el
    end
  end

  @impl true
  def screenshot(sessions, w, url, ready) do
    s = sessions |> session(w) |> open(url, ready)
    # The documented call writes the PNG to :screenshot_dir; read it back.
    %{screenshots: shots} = Browser.take_screenshot(s, name: "w#{w}")
    path = List.last(shots)
    png = File.read!(path)
    File.rm(path)
    {:ok, png}
  end

  @impl true
  def pdf(_, _, _, _),
    do: {:unsupported, "no print/PDF in Wallaby.Browser or its WebDriver client"}

  @impl true
  def text(sessions, w, url, ready, css) do
    s = sessions |> session(w) |> open(url, ready)
    {:ok, s |> first(css) |> Element.text()}
  end

  @impl true
  def click(sessions, w, url, ready, click, after_css) do
    s = sessions |> session(w) |> open(url, ready)
    s |> first(click) |> Element.click()
    {:ok, s |> first(after_css) |> Element.text()}
  end

  @doc "Firefox through a Selenium server (SELENIUM_URL), in the probe-only run."
  def browser_probes(fx) do
    [
      firefox: fn ->
        Application.put_env(:wallaby, :driver, Wallaby.Selenium)
        Application.put_env(:wallaby, :js_logger, nil)
        {:ok, _} = Application.ensure_all_started(:wallaby)

        # Selenium 4 first (the current server), then Selenium 3: Wallaby sends
        # JSON Wire `desiredCapabilities`, which only the old server accepts.
        case firefox_on(System.fetch_env!("SELENIUM_URL"), fx) do
          {:ok, text} ->
            {:partial, "Wallaby.Selenium and a Selenium 4 server next to it", text}

          {:error, why4} ->
            case firefox_on(System.fetch_env!("SELENIUM3_URL"), fx) do
              {:ok, text} ->
                {:partial,
                 "only with a Selenium 3 server (3.141.59, amd64 only): Selenium 4 refused the session (#{why4})",
                 text}

              {:error, why3} ->
                {:fail, "Selenium 4: #{why4}; Selenium 3: #{why3}"}
            end
        end
      end,
      webkit: fn ->
        {:unsupported, "drivers are Chrome (ChromeDriver) and Selenium; no WebKit driver"}
      end
    ]
  end

  defp firefox_on(url, fx) do
    Application.put_env(:wallaby, :selenium, remote_url: url)

    try do
      {:ok, s} = Wallaby.start_session(capabilities: %{browserName: "firefox"})

      try do
        text = s |> Browser.visit(fx.base <> "/probe/") |> first("#title") |> Element.text()
        {:ok, "firefox: read #{inspect(text)}"}
      after
        Wallaby.end_session(s)
      end
    rescue
      e -> {:error, e |> Exception.message() |> String.slice(0, 120)}
    end
  end

  @impl true
  def probes(sessions, fx) do
    url = fx.base <> "/probe/"
    s = session(sessions, 0)
    p = fn fun -> fn -> {:ok, fun.(open(s, url, :load))} end end

    [
      evaluate:
        p.(fn s ->
          Browser.execute_script(s, "window.__r = 1 + 2; return window.__r", [], fn v ->
            send(self(), {:js, v})
          end)

          receive do
            {:js, v} -> v
          after
            5_000 -> raise "no result"
          end
        end),
      fill_form:
        p.(fn s ->
          s
          |> Browser.fill_in(Query.css("#name"), with: "Alice")
          |> Browser.set_value(Query.css("#color option[value=green]"), :selected)
          |> Browser.set_value(Query.css("#agree"), :selected)

          Browser.execute_script(
            s,
            "return [name.value, color.value, agree.checked].join(',')",
            [],
            fn v ->
              send(self(), {:js, v})
            end
          )

          receive do
            {:js, v} -> v
          after
            5_000 -> raise "no result"
          end
        end),
      file_upload:
        p.(fn s ->
          path = Path.join(System.tmp_dir!(), "upload.txt")
          File.write!(path, "x")
          s |> Browser.attach_file(Query.css("#file"), path: path)
          s |> first("#fileName") |> Element.text()
        end),
      dialog:
        p.(fn s ->
          Browser.accept_confirm(s, fn s -> Browser.click(s, Query.css("#alert")) end)
          s |> first("#dialog") |> Element.text()
        end),
      hover:
        p.(fn s ->
          s |> Browser.hover(Query.css("#hover"))
          s |> first("#hover") |> Element.text()
        end),
      iframe_content:
        p.(fn s ->
          Browser.focus_frame(s, Query.css("#embed"))
          text = s |> first("#inside") |> Element.text()
          Browser.focus_parent_frame(s)
          text
        end),
      wait_selector: fn ->
        open(s, fx.base <> "/js/", {:css, ".article-preview"})
        {:ok, "find/2 blocks until the query matches (max_wait_time)"}
      end,
      wait_js: fn ->
        {:unsupported, "no wait on a JS predicate; queries wait for elements only"}
      end,
      wait_network_idle: fn -> {:unsupported, "no network events in WebDriver classic"} end,
      wait_response_body: fn -> {:unsupported, "no network events in WebDriver classic"} end,
      cookies:
        p.(fn s ->
          Browser.set_cookie(s, "probe", "1")
          s |> Browser.cookies() |> Enum.map(& &1["name"])
        end),
      console: fn ->
        {:ok, io} = StringIO.open("")
        Application.put_env(:wallaby, :js_logger, io)

        try do
          open(s, url, :load)
          # Logs are pulled after each command.
          s |> first("#title")
          {_, out} = StringIO.contents(io)

          if String.contains?(out, "probe-console"),
            do: {:ok, "js_logger got the console line"},
            else: {:fail, "js_logger got: #{inspect(out)}"}
        after
          Application.put_env(:wallaby, :js_logger, nil)
        end
      end,
      viewport_ua: fn ->
        {:ok, s2} =
          Wallaby.start_session(
            capabilities: %{
              javascriptEnabled: true,
              chromeOptions: %{
                args: [
                  "--headless",
                  "--no-sandbox",
                  "--window-size=400,300",
                  "--user-agent=probe-agent"
                ]
              }
            }
          )

        try do
          s2 = open(s2, url, :load)

          Browser.execute_script(
            s2,
            "return innerWidth + 'x' + innerHeight + ' ' + navigator.userAgent",
            [],
            fn v ->
              send(self(), {:js, v})
            end
          )

          receive do
            {:js, v} -> {:ok, v}
          after
            5_000 -> raise "no result"
          end
        after
          Wallaby.end_session(s2)
        end
      end,
      isolation: fn ->
        open(s, url, :load) |> Browser.set_cookie("a", "1")
        {:ok, s2} = Wallaby.start_session()

        try do
          names = s2 |> open(url, :load) |> Browser.cookies() |> Enum.map(& &1["name"])

          case Compare.Probe.isolated(names) do
            {:ok, ev} -> {:ok, "a session per job (one Chrome each): " <> ev}
            other -> other
          end
        after
          Wallaby.end_session(s2)
        end
      end,
      telemetry: fn ->
        Compare.Probe.telemetry(:wallaby, fn ->
          screenshot(sessions, 0, fx.base <> "/html/", :load)
        end)
      end,
      attach: fn ->
        Compare.Probe.with_debug_chrome(fn %{port: port} ->
          {:ok, s2} =
            Wallaby.start_session(
              capabilities: %{
                javascriptEnabled: true,
                chromeOptions: %{args: [], debuggerAddress: "127.0.0.1:#{port}"}
              }
            )

          try do
            text = s2 |> open(url, :load) |> first("#title") |> Element.text()

            {:partial, "ChromeDriver's debuggerAddress capability, passed through start_session/1",
             text}
          after
            Wallaby.end_session(s2)
          end
        end)
      end,
      download: fn -> {:unsupported, "no download API"} end,
      interception: fn -> {:unsupported, "no network interception in WebDriver classic"} end,
      block_by_type: fn -> {:unsupported, "no network interception in WebDriver classic"} end,
      cross_site_block: fn -> {:unsupported, "no network interception in WebDriver classic"} end,
      site_login: fn -> {:unsupported, "no HTTP auth API"} end,
      proxy_auth: fn ->
        {:unsupported, "--proxy-server via capabilities, but no way to answer the proxy's login"}
      end,
      pool: fn -> {:unsupported, "no pool; one session per test or job"} end,
      timezone: fn -> {:unsupported, "no timezone API"} end,
      clock: fn -> {:unsupported, "no clock API"} end,
      tracing: fn -> {:unsupported, "no tracing API"} end,
      firefox: fn -> {:unsupported, "needs the Selenium driver; probed in the browsers run"} end,
      webkit: fn ->
        {:unsupported, "drivers are Chrome (ChromeDriver) and Selenium; no WebKit driver"}
      end,
      pdf_a: fn -> {:unsupported, "no PDF API"} end,
      pdf_header_footer: fn -> {:unsupported, "no PDF API"} end,
      html_string_pdf: fn -> {:unsupported, "no PDF API"} end
    ]
  end
end
