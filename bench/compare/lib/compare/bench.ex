defmodule Compare.Bench do
  @moduledoc """
  One container run: `LIB`, `TASK`, `PAGE` from the environment. Prints one JSON
  line to stdout. Tasks: `screenshot`, `pdf`, `text`, `click` (on `js` only),
  `cold`, `concurrent`, and `probe` (every capability probe; writes
  `RESULTS_DIR/capabilities-<lib>.json`).
  """

  alias Compare.{Fixture, Lib, Sampler}

  def int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  def main do
    lib = Lib.by_name(System.fetch_env!("LIB"))
    task = System.fetch_env!("TASK")
    page = System.get_env("PAGE", "html")
    fx = Fixture.from_env()

    result =
      case task do
        "probe" -> probe(lib, fx)
        "probe_browsers" -> probe_browsers(lib, fx)
        _ -> timed(lib, task, page, fx)
      end

    meta = %{lib: lib.name(), version: lib.version(), task: task, page: page, setup: setup(lib)}
    IO.puts(Jason.encode!(Map.merge(meta, result)))
  end

  defp setup(Compare.CDPEx), do: Compare.CDPEx.setup()
  defp setup(_), do: "default"

  defp probe(lib, fx) do
    rows = Compare.Probe.run(lib, fx)
    dir = System.get_env("RESULTS_DIR", "/tmp")
    File.write!(Path.join(dir, "capabilities-#{lib.name()}.json"), Jason.encode!(rows))
    %{rows: length(rows)}
  end

  defp probe_browsers(lib, fx) do
    Code.ensure_loaded(lib)
    rows = Compare.Probe.run_browsers(lib, fx)
    dir = System.get_env("RESULTS_DIR", "/tmp")
    File.write!(Path.join(dir, "capabilities-#{lib.name()}-browsers.json"), Jason.encode!(rows))
    %{rows: length(rows)}
  end

  defp job_fun(lib, "cold", _page, fx) do
    url = Fixture.url(fx, "html")

    fn _st, _w ->
      st = lib.start(parallel: 1)
      {:ok, _} = lib.screenshot(st, 0, url, :load)
      lib.stop(st)
    end
  end

  defp job_fun(lib, task, page, fx) do
    p = Fixture.page(page)
    url = Fixture.url(fx, page)

    fn st, w ->
      case task do
        "screenshot" -> lib.screenshot(st, w, url, p.ready)
        "pdf" -> lib.pdf(st, w, url, p.ready)
        "text" -> lib.text(st, w, url, p.ready, p.text)
        "click" -> lib.click(st, w, url, p.ready, Fixture.click_target(), Fixture.after_click())
        "concurrent" -> lib.screenshot(st, w, url, p.ready)
      end
      |> case do
        {:ok, _} -> :ok
        {:partial, how, _} -> Process.put(:partial, how) && :ok
        {:unsupported, why} -> throw({:unsupported, why})
      end
    end
  end

  defp timed(lib, task, page, fx) do
    parallel = if task == "concurrent", do: int("CONCURRENCY", 8), else: 1
    job = job_fun(lib, task, page, fx)
    st = if task == "cold", do: nil, else: lib.start(parallel: parallel)

    try do
      # Warm-up, not counted: one job per worker.
      for w <- 0..(parallel - 1), do: job.(st, w)
      sampler = Sampler.start()

      measured =
        if task == "concurrent", do: concurrent(job, st, parallel), else: sequential(job, st, task)

      measured
      |> Map.merge(Sampler.stop(sampler))
      |> Map.put(:partial, Process.get(:partial))
    catch
      {:unsupported, why} -> %{unsupported: why}
    after
      if st, do: lib.stop(st)
    end
  end

  defp sequential(job, st, task) do
    n = int("ITERATIONS", if(task == "cold", do: 10, else: 20))

    samples =
      for _ <- 1..n do
        {us, _} = :timer.tc(fn -> job.(st, 0) end)
        us / 1000
      end

    sorted = Enum.sort(samples)
    %{samples_ms: samples, p50_ms: pct(sorted, 0.5), p95_ms: pct(sorted, 0.95)}
  end

  defp concurrent(job, st, parallel) do
    seconds = int("DURATION_S", 20)
    deadline = System.monotonic_time(:millisecond) + seconds * 1000

    {us, latencies} =
      :timer.tc(fn ->
        0..(parallel - 1)
        |> Enum.map(fn w ->
          Task.async(fn ->
            Stream.repeatedly(fn ->
              {us, _} = :timer.tc(fn -> job.(st, w) end)
              us / 1000
            end)
            |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
            |> Enum.to_list()
          end)
        end)
        |> Task.await_many(:infinity)
        |> List.flatten()
      end)

    sorted = Enum.sort(latencies)

    %{
      jobs: length(latencies),
      jobs_per_s: Float.round(length(latencies) / (us / 1_000_000), 2),
      p50_ms: pct(sorted, 0.5),
      p95_ms: pct(sorted, 0.95)
    }
  end

  defp pct([], _), do: nil
  defp pct(sorted, p), do: Enum.at(sorted, min(round(p * length(sorted)), length(sorted) - 1))
end
