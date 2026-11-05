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
      # One warm browser; CONCURRENCY workers run static-page jobs back to back for
      # DURATION_S seconds.
      browser = ok.(CDPEx.launch(launch_opts))
      job.(browser, "/", title)
      seconds = int.("DURATION_S", 20)
      deadline = System.monotonic_time(:millisecond) + seconds * 1000

      worker = fn ->
        fn -> job.(browser, "/", title) end
        |> Stream.repeatedly()
        |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
        |> Enum.count()
      end

      {us, counts} =
        :timer.tc(fn ->
          1..int.("CONCURRENCY", 8)
          |> Enum.map(fn _ -> Task.async(worker) end)
          |> Task.await_many(:infinity)
        end)

      :ok = CDPEx.stop(browser)
      %{jobs: Enum.sum(counts), seconds: us / 1_000_000}
  end

# The options go into the result so runs with different ones can be told apart.
meta = %{
  lib: "cdp_ex",
  scenario: scenario,
  launch_opts: inspect(launch_opts),
  page_opts: inspect(page_opts)
}

IO.puts(Jason.encode!(Map.merge(meta, result)))
