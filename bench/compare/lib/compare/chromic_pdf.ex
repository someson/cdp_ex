defmodule Compare.ChromicPDF do
  @moduledoc """
  ChromicPDF: its own supervisor with a `session_pool` of one tab per worker, the
  documented way to run parallel prints. Every job is one `capture_screenshot/2`
  or `print_to_pdf/2` call on a URL; `ready` maps to its `:wait_for` option.
  """
  @behaviour Compare.Lib

  @impl true
  def name, do: "chromic_pdf"

  @impl true
  def version, do: Compare.Lib.dep_version(:chromic_pdf)

  @impl true
  def start(opts) do
    size = Keyword.get(opts, :parallel, 1)

    {:ok, sup} =
      ChromicPDF.start_link(
        [
          chrome_executable: System.fetch_env!("CHROME"),
          # Headless Chrome gives the page 143 px less than the window; this makes
          # the viewport 1280x800 like the others (the probe checks the PNG size).
          chrome_args: "--window-size=1280,943",
          # Documented for Docker; the other libraries pass --no-sandbox too.
          no_sandbox: true,
          session_pool: [size: size, timeout: 30_000]
        ] ++ Keyword.get(opts, :extra, [])
      )

    Process.unlink(sup)
    # Sessions spawn at start; one call makes sure Chrome is up before timing.
    {:ok, _} = ChromicPDF.capture_screenshot({:html, "<p>warm</p>"})
    sup
  end

  @impl true
  def stop(sup) do
    ref = Process.monitor(sup)
    Process.exit(sup, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp wait_for(:load), do: []

  # `:wait_for` polls an element that must already exist for an attribute; it
  # raises when the element isn't rendered yet. So a page that renders later is
  # waited for with `:evaluate` returning a Promise, which ChromicPDF awaits.
  defp wait_for({:css, css}),
    do: [
      evaluate: %{
        expression:
          "new Promise(r => { const t = () => document.querySelector(#{Jason.encode!(css)}) ? r() : setTimeout(t, 10); t(); })"
      }
    ]

  @wait_how "no wait for an element to appear; an :evaluate Promise that polls for it"
  defp tag({:css, _}, value), do: {:partial, @wait_how, value}
  defp tag(:load, value), do: {:ok, value}

  @impl true
  def screenshot(_sup, _w, url, ready) do
    {:ok, b64} = ChromicPDF.capture_screenshot({:url, url}, wait_for(ready))
    tag(ready, Base.decode64!(b64))
  end

  @impl true
  def pdf(_sup, _w, url, ready) do
    {:ok, b64} = ChromicPDF.print_to_pdf({:url, url}, wait_for(ready))
    tag(ready, Base.decode64!(b64))
  end

  @impl true
  def text(_, _, _, _, _),
    do:
      {:unsupported,
       "no DOM or JS result is returned; `:evaluate` runs JS before printing and discards its value"}

  @impl true
  def click(_, _, _, _, _, _),
    do:
      {:unsupported,
       "no input or DOM API; `:evaluate` can click from JS, but nothing reads the result back"}

  @none "ChromicPDF prints and captures; no API for it"

  @impl true
  def probes(_sup, fx) do
    url = fx.base <> "/probe/"

    [
      pdf_a: fn ->
        # The fixture pages and a plain HTML string; Ghostscript drops PDF/A for a
        # page whose fonts it can't embed compliantly, and says so on stderr.
        sources = [
          probe: {:url, url},
          html: {:url, fx.base <> "/html/"},
          string: {:html, "<p>Hello</p>"}
        ]

        results =
          for {name, source} <- sources do
            {:ok, b64} = ChromicPDF.print_to_pdfa(source)
            {name, Compare.Check.pdfa(Base.decode64!(b64))}
          end

        ok = for {name, {:ok, _}} <- results, do: name
        notes = Enum.map_join(results, "; ", fn {n, {r, ev}} -> "#{n}: #{r} #{ev}" end)

        cond do
          length(ok) == length(sources) ->
            {:ok, notes}

          # Done through the API; the page it couldn't convert is in the note.
          ok != [] ->
            {:ok,
             "Ghostscript fell back to plain PDF for one page (a CIDFont uses CID 0); " <> notes}

          true ->
            {:fail, notes}
        end
      end,
      pdf_header_footer: fn ->
        header = %{
          displayHeaderFooter: true,
          headerTemplate: ~s(<span style="font-size:10px">probe header</span>),
          footerTemplate: ~s(<span class="pageNumber" style="font-size:10px"></span>),
          marginTop: 1,
          marginBottom: 1
        }

        {:ok, with_header} = ChromicPDF.print_to_pdf({:url, url}, print_to_pdf: header)
        {:ok, without} = ChromicPDF.print_to_pdf({:url, url})
        Compare.Check.pdf_header(Base.decode64!(with_header), Base.decode64!(without))
      end,
      html_string_pdf: fn ->
        {:ok, b64} = ChromicPDF.print_to_pdf({:html, "<h1>from a string</h1>"})
        Compare.Check.pdf(Base.decode64!(b64))
      end,
      wait_selector: fn ->
        {:ok, _} =
          ChromicPDF.capture_screenshot(
            {:url, fx.base <> "/js/"},
            wait_for({:css, ".article-preview"})
          )

        {:partial, @wait_how <> " (:wait_for needs the element to exist already)", "waited"}
      end,
      evaluate: fn ->
        {:ok, _} = ChromicPDF.capture_screenshot({:url, url}, evaluate: %{expression: "1 + 2"})
        {:partial, ":evaluate runs JS before the capture; its value isn't returned", "ran"}
      end,
      cookies: fn ->
        {:ok, _} =
          ChromicPDF.capture_screenshot({:url, url},
            set_cookie: %{name: "probe", value: "1", domain: URI.parse(url).host}
          )

        {:partial, "set_cookie before navigating; cookies can't be read back", "set"}
      end,
      timezone: fn ->
        {:ok, _} = ChromicPDF.capture_screenshot({:url, url}, timezone: "Asia/Tokyo")
        {:partial, "timezone option on a capture; the effect is only visible in the output", "set"}
      end,
      isolation: fn ->
        {:unsupported, "sessions are reused tabs in one browser context; no context per job"}
      end,
      pool: fn ->
        results =
          1..2
          |> Task.async_stream(fn _ -> ChromicPDF.capture_screenshot({:html, "<p>x</p>"}) end)
          |> Enum.map(fn {:ok, {:ok, _}} -> :ok end)

        {:ok, "#{length(results)} jobs on the session pool"}
      end,
      telemetry: fn ->
        Compare.Probe.telemetry(:chromic_pdf, fn -> ChromicPDF.capture_screenshot({:url, url}) end)
      end,
      viewport_ua: fn ->
        {:unsupported, "no per-capture viewport or user agent; only Chrome args at start"}
      end,
      fill_form: fn -> {:unsupported, @none} end,
      file_upload: fn -> {:unsupported, @none} end,
      download: fn -> {:unsupported, @none} end,
      dialog: fn -> {:unsupported, @none} end,
      hover: fn -> {:unsupported, @none} end,
      console: fn -> {:unsupported, @none} end,
      iframe_content: fn -> {:unsupported, @none} end,
      wait_js: fn ->
        {:unsupported, "only :wait_for (selector + attribute) and an awaited :evaluate promise"}
      end,
      wait_network_idle: fn -> {:unsupported, "waits for frameStoppedLoading only"} end,
      wait_response_body: fn -> {:unsupported, @none} end,
      interception: fn -> {:unsupported, @none} end,
      block_by_type: fn -> {:unsupported, @none} end,
      cross_site_block: fn -> {:unsupported, @none} end,
      site_login: fn -> {:unsupported, "no HTTP auth option"} end,
      proxy_auth: fn ->
        {:unsupported,
         "no proxy option; --proxy-server via chrome_args has no way to answer the login"}
      end,
      clock: fn -> {:unsupported, @none} end,
      tracing: fn -> {:unsupported, @none} end,
      firefox: fn -> {:unsupported, "Chrome / Chromium only"} end,
      webkit: fn -> {:unsupported, "Chrome / Chromium only"} end,
      # Last: it restarts the ChromicPDF supervisor.
      attach: fn -> attach_probe(fx) end
    ]
  end

  defp attach_probe(fx) do
    # ChromicPDF runs under a global name: stop the probe's own instance, attach
    # one to a Chrome started outside it, then start the regular one again.
    Supervisor.stop(ChromicPDF)

    try do
      Compare.Probe.with_debug_chrome(fn %{port: port} ->
        {:ok, sup} = ChromicPDF.start_link(chrome_address: {"127.0.0.1", port}, no_sandbox: true)
        Process.unlink(sup)

        try do
          {:ok, b64} = ChromicPDF.capture_screenshot({:url, fx.base <> "/probe/"})

          {:ok,
           "chrome_address (its docs call it experimental); #{byte_size(Base.decode64!(b64))} B PNG"}
        after
          Supervisor.stop(sup)
        end
      end)
    after
      start([])
    end
  end
end
