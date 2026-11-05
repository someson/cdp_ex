// Collects and summarises benchmark results.
//
//   node bench/report.mjs add <results.jsonl> <round> <result.json> [<sample.json>]
//   node bench/report.mjs table <results.jsonl>
//
// `add` appends one line: the scenario's result, merged with the sampler's peaks
// when given. `table` prints a Markdown table with the median over rounds of each
// round's figures: p50/p95 of the timed samples, or jobs/s for `concurrent`.
import fs from "node:fs";

const [command, file, ...rest] = process.argv.slice(2);

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

const percentile = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};

const lastJson = (path) => {
  const lines = fs.readFileSync(path, "utf8").trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
};

if (command === "add") {
  const [round, resultPath, samplePath] = rest;
  const result = lastJson(resultPath);
  const sample = samplePath && fs.existsSync(samplePath) ? lastJson(samplePath) : {};
  fs.appendFileSync(file, JSON.stringify({ round: Number(round), ...result, ...sample }) + "\n");
} else if (command === "table") {
  const rows = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  const groups = new Map();

  for (const row of rows) {
    const key = `${row.scenario}\t${row.lib}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }

  const metric = (runs, f) => {
    const values = runs.map(f).filter((v) => v !== undefined && !Number.isNaN(v));
    return values.length ? median(values) : undefined;
  };

  const fmt = (v, digits = 0) => (v === undefined ? "–" : v.toFixed(digits));

  console.log("| Scenario | Library | p50 ms | p95 ms | jobs/s | peak PSS MB | peak procs | CPU s | rounds |");
  console.log("|---|---|---|---|---|---|---|---|---|");

  for (const [key, runs] of [...groups].sort()) {
    const [scenario, lib] = key.split("\t");
    const p50 = metric(runs, (r) => r.samples_ms && median(r.samples_ms));
    const p95 = metric(runs, (r) => r.samples_ms && percentile(r.samples_ms, 95));
    const rate = metric(runs, (r) => (r.jobs === undefined ? undefined : r.jobs / r.seconds));

    console.log(
      `| ${scenario} | ${lib} | ${fmt(p50)} | ${fmt(p95)} | ${fmt(rate, 1)} | ` +
        `${fmt(metric(runs, (r) => r.peak_pss_mb))} | ${fmt(metric(runs, (r) => r.peak_procs))} | ` +
        `${fmt(metric(runs, (r) => r.cpu_s), 1)} | ${runs.length} |`,
    );
  }
} else {
  console.error("usage: report.mjs add <results.jsonl> <round> <result.json> [<sample.json>] | table <results.jsonl>");
  process.exit(2);
}
