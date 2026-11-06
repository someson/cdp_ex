defmodule Compare.Sampler do
  @moduledoc """
  Samples the container while a task runs: every `INTERVAL_MS` the PSS of every
  process, summed by kind (browser, driver, beam), from `/proc`. At the end, the
  container's cgroup numbers: `memory.peak` (since the container started) and
  the CPU used since `start/0`.
  """
  use GenServer

  @cg "/sys/fs/cgroup"

  def start do
    {:ok, pid} = GenServer.start(__MODULE__, Compare.Bench.int("INTERVAL_MS", 100))
    pid
  end

  def stop(pid), do: GenServer.call(pid, :stop)

  @impl true
  def init(interval) do
    send(self(), :sample)
    {:ok, %{interval: interval, cpu0: cpu_usec(), peak: %{}, peak_total: 0, procs: 0}}
  end

  @impl true
  def handle_info(:sample, st) do
    by_kind = sample()
    total = by_kind |> Map.values() |> Enum.map(& &1.kb) |> Enum.sum()
    procs = by_kind |> Map.values() |> Enum.map(& &1.n) |> Enum.sum()
    peak = Map.merge(st.peak, by_kind, fn _, a, b -> %{kb: max(a.kb, b.kb), n: max(a.n, b.n)} end)
    Process.send_after(self(), :sample, st.interval)

    {:noreply,
     %{st | peak: peak, peak_total: max(st.peak_total, total), procs: max(st.procs, procs)}}
  end

  @impl true
  def handle_call(:stop, _from, st) do
    result = %{
      cpu_s: (cpu_usec() - st.cpu0) / 1_000_000,
      cgroup_peak_mb: mem_peak_mb(),
      pss_peak_mb: div(st.peak_total, 1024),
      peak_procs: st.procs,
      pss_by_kind_mb: Map.new(st.peak, fn {k, v} -> {k, div(v.kb, 1024)} end),
      procs_by_kind: Map.new(st.peak, fn {k, v} -> {k, v.n} end)
    }

    {:stop, :normal, result, st}
  end

  defp sample do
    "/proc"
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^\d+$/))
    |> Enum.reduce(%{}, fn pid, acc ->
      with {:ok, exe} <- File.read_link("/proc/#{pid}/exe"),
           kind when kind != nil <- kind(exe),
           {:ok, rollup} <- File.read("/proc/#{pid}/smaps_rollup"),
           [_, kb] <- Regex.run(~r/^Pss:\s+(\d+) kB/m, rollup) do
        Map.update(acc, kind, %{kb: String.to_integer(kb), n: 1}, fn m ->
          %{kb: m.kb + String.to_integer(kb), n: m.n + 1}
        end)
      else
        _ -> acc
      end
    end)
  end

  defp kind(exe) do
    cond do
      exe =~ ~r{/chromium/chromium$|/chrome$} -> "browser"
      exe =~ ~r{chromedriver$} -> "driver"
      exe =~ ~r{/node(js)?$} -> "driver"
      exe =~ ~r{beam\.smp$} -> "beam"
      true -> nil
    end
  end

  defp cpu_usec do
    case File.read(@cg <> "/cpu.stat") do
      {:ok, s} ->
        s |> then(&Regex.run(~r/usage_usec (\d+)/, &1)) |> List.last() |> String.to_integer()

      _ ->
        0
    end
  end

  defp mem_peak_mb do
    case File.read(@cg <> "/memory.peak") do
      {:ok, s} -> div(s |> String.trim() |> String.to_integer(), 1024 * 1024)
      _ -> nil
    end
  end
end
