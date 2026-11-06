# CDPEx side of the benchmark. Run from the repository root:
#
#   BASE_URL=http://127.0.0.1:8080 SCENARIO=cold mix run bench/cdp_ex.exs
#
# Prints one JSON line with the result. See bench/README.md for the scenarios and
# the environment variables. Launch options come from CDP_EX_LAUNCH_OPTS and page
# options from CDP_EX_PAGE_OPTS, both Elixir keyword lists (e.g. "[pipe: true]").
alias CDPEx.Page

env = fn name, default -> System.get_env(name, default) end
int = fn name, default -> name |> env.(Integer.to_string(default)) |> String.to_integer() end
opts = fn name -> name |> env.("[]") |> Code.eval_string() |> elem(0) end

base = String.trim_trailing(env.("BASE_URL", "http://127.0.0.1:8080"), "/")
scenario = env.("SCENARIO", "cold")
launch_opts = opts.("CDP_EX_LAUNCH_OPTS")
page_opts = opts.("CDP_EX_PAGE_OPTS")

ok = fn
  {:ok, value} -> value
  {:ok, value, _} -> value
  other -> raise "unexpected result: #{inspect(other)}"
end

timed = fn fun ->
  {us, _} = :timer.tc(fun)
  us / 1000
end

# One job: open a page, load `path`, run `check`, close the page.
job = fn browser, path, check ->
  page = ok.(CDPEx.new_page(browser, page_opts))
  ok.(Page.navigate(page, base <> path, wait_until: :load))
  check.(page)
  :ok = CDPEx.close_page(browser, page)
end

title = fn page -> ok.(Page.evaluate(page, "document.title")) end
items = fn page -> :ok = Page.wait_for_selector(page, ".item") end

result =
  case scenario do
    "cold" ->
      # launch -> page -> navigate -> stop, once per iteration. The first run is a
      # warm-up (disk cache, dynamic linking) and isn't counted.
      cycle = fn ->
        browser = ok.(CDPEx.launch(launch_opts))
        job.(browser, "/", title)
        :ok = CDPEx.stop(browser)
      end

      cycle.()
      %{samples_ms: for(_ <- 1..int.("ITERATIONS", 10), do: timed.(cycle))}

    "spa" ->
      # One warm browser; per iteration a page loads the SPA and waits for its items.
      browser = ok.(CDPEx.launch(launch_opts))
      job.(browser, "/spa", items)

      samples =
        for _ <- 1..int.("ITERATIONS", 20), do: timed.(fn -> job.(browser, "/spa", items) end)

      :ok = CDPEx.stop(browser)
      %{samples_ms: samples}

    "concurrent" ->
      # BROWSERS warm browsers (default 1); CONCURRENCY workers, spread over them
      # round-robin, run static-page jobs back to back for DURATION_S seconds. Each
      # job's new_page/2 time is kept: on a shared browser it includes the wait
      # behind the other pages' setup, which the Browser serves one at a time.
      browsers = for _ <- 1..int.("BROWSERS", 1), do: ok.(CDPEx.launch(launch_opts))
      Enum.each(browsers, &job.(&1, "/", title))
      seconds = int.("DURATION_S", 20)
      deadline = System.monotonic_time(:millisecond) + seconds * 1000

      timed_job = fn browser ->
        {us, page} = :timer.tc(fn -> ok.(CDPEx.new_page(browser, page_opts)) end)
        ok.(Page.navigate(page, base <> "/", wait_until: :load))
        title.(page)
        :ok = CDPEx.close_page(browser, page)
        us / 1000
      end

      worker = fn browser ->
        fn -> timed_job.(browser) end
        |> Stream.repeatedly()
        |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
        |> Enum.to_list()
      end

      {us, new_page_ms} =
        :timer.tc(fn ->
          1..int.("CONCURRENCY", 8)
          |> Enum.map(fn i -> Enum.at(browsers, rem(i - 1, length(browsers))) end)
          |> Enum.map(fn browser -> Task.async(fn -> worker.(browser) end) end)
          |> Task.await_many(:infinity)
          |> List.flatten()
        end)

      Enum.each(browsers, &(:ok = CDPEx.stop(&1)))
      sorted = Enum.sort(new_page_ms)
      pct = fn p -> Enum.at(sorted, min(round(p * length(sorted)), length(sorted) - 1)) end

      %{
        jobs: length(new_page_ms),
        seconds: us / 1_000_000,
        browsers: length(browsers),
        new_page_p50_ms: pct.(0.5),
        new_page_p95_ms: pct.(0.95)
      }
  end

# The options go into the result so runs with different ones can be told apart.
meta = %{
  lib: "cdp_ex",
  scenario: scenario,
  launch_opts: inspect(launch_opts),
  page_opts: inspect(page_opts)
}

IO.puts(Jason.encode!(Map.merge(meta, result)))
