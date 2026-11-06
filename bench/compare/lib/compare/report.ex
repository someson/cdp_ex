defmodule Compare.Report do
  @moduledoc "Turns a results dir into Markdown: the capability matrix and the timing table (medians over rounds)."

  @libs ["cdp_ex", "playwright_ex", "chromic_pdf", "wallaby"]

  def main(dir) do
    IO.puts(capabilities(dir))
    IO.puts(timings(dir))
  end

  def capabilities(dir) do
    rows =
      for lib <- @libs,
          path = Path.join(dir, "capabilities-#{lib}.json"),
          File.exists?(path),
          row <- path |> File.read!() |> Jason.decode!(),
          do: row

    # The probe-only browsers run (Firefox / WebKit) overrides those rows.
    browsers =
      for lib <- @libs,
          path = Path.join(dir, "capabilities-#{lib}-browsers.json"),
          File.exists?(path),
          row <- path |> File.read!() |> Jason.decode!(),
          do: row

    versions = rows |> Enum.map(&{&1["lib"], &1["version"]}) |> Enum.uniq()
    libs = Enum.map(versions, &elem(&1, 0))
    by = Map.new(rows ++ browsers, &{{&1["key"], &1["lib"]}, &1})

    header =
      "| Capability | " <>
        Enum.map_join(versions, " | ", fn {l, v} -> "#{l} #{v}" end) <>
        " |\n" <>
        "|---|" <> String.duplicate("---|", length(libs)) <> "\n"

    body =
      for {key, label} <- Compare.Probe.capabilities(), into: "" do
        cells = Enum.map_join(libs, " | ", &cell(by[{to_string(key), &1}]))
        "| #{label} | #{cells} |\n"
      end

    notes =
      for {key, label} <- Compare.Probe.capabilities(),
          lib <- libs,
          r = by[{to_string(key), lib}],
          r,
          into: "" do
        "- #{label} / #{lib}: **#{r["result"]}** #{r["note"]}\n"
      end

    "## Capabilities\n\n" <> header <> body <> "\n### Probe notes\n\n" <> notes
  end

  defp cell(nil), do: ""
  defp cell(%{"result" => "ok"}), do: "✓"
  defp cell(%{"result" => "partial"}), do: "partial"
  defp cell(%{"result" => "unsupported"}), do: "✗"
  defp cell(%{"result" => r}), do: r

  def timings(dir) do
    runs =
      dir
      |> Path.join("results.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.reject(&(&1["task"] == "probe"))

    groups =
      runs
      |> Enum.group_by(&{&1["task"], &1["page"], label(&1)})
      |> Enum.sort_by(fn {{t, p, l}, _} -> {task_order(t), p, lib_order(l)} end)

    header =
      "## Timings (medians over rounds)\n\n" <>
        "| Task | Page | Library | p50 ms | p95 ms | jobs/s | memory peak MB | PSS peak MB (browser / driver / beam) | procs | CPU s |\n" <>
        "|---|---|---|---|---|---|---|---|---|---|\n"

    body =
      for {{task, page, lib}, rs} <- groups, into: "" do
        if why = Enum.find_value(rs, & &1["unsupported"]) do
          "| #{task} | #{page} | #{lib} | can't | | | | #{why} | | |\n"
        else
          kinds = fn k -> med(rs, &get_in(&1, ["pss_by_kind_mb", k])) |> fmt() end

          lib = if Enum.any?(rs, & &1["partial"]), do: lib <> " ¹", else: lib

          "| #{task} | #{page} | #{lib} | #{med(rs, & &1["p50_ms"]) |> fmt()} | #{med(rs, & &1["p95_ms"]) |> fmt()} | " <>
            "#{med(rs, & &1["jobs_per_s"]) |> fmt(1)} | #{med(rs, & &1["cgroup_peak_mb"]) |> fmt()} | " <>
            "#{med(rs, & &1["pss_peak_mb"]) |> fmt()} (#{kinds.("browser")} / #{kinds.("driver")} / #{kinds.("beam")}) | " <>
            "#{med(rs, & &1["peak_procs"]) |> fmt()} | #{med(rs, & &1["cpu_s"]) |> fmt(1)} |\n"
        end
      end

    partials =
      runs
      |> Enum.map(& &1["partial"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map_join("\n", &("¹ " <> &1))

    header <>
      body <>
      "\n" <>
      partials <>
      "\n\nRounds per row: #{runs |> Enum.frequencies_by(&{&1["task"], &1["page"], label(&1)}) |> Map.values() |> Enum.max(fn -> 0 end)}\n"
  end

  defp label(%{"lib" => "cdp_ex", "setup" => "pool"}), do: "cdp_ex (pool)"
  defp label(%{"lib" => lib}), do: lib

  @tasks ~w(screenshot pdf text click cold concurrent)
  defp task_order(t), do: Enum.find_index(@tasks, &(&1 == t)) || 99
  defp lib_order(l), do: Enum.find_index(@libs ++ ["cdp_ex (pool)"], &(&1 == l)) || 99

  defp med(rs, f) do
    case rs |> Enum.map(f) |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      xs -> Enum.at(xs, div(length(xs), 2))
    end
  end

  defp fmt(v, d \\ 0)
  defp fmt(nil, _), do: "–"
  defp fmt(v, 0) when is_number(v), do: v |> round() |> to_string()
  defp fmt(v, d) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: d)
end
