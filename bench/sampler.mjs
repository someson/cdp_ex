// Samples the memory and CPU of every process running the browser binary, Linux
// only (it reads /proc). Every INTERVAL_MS it sums the PSS of those processes and
// counts them; on SIGTERM it prints one JSON line with the peaks and the CPU time
// they used, then exits.
//
//   node bench/sampler.mjs /path/to/chrome > sample.json &
//   ...run a scenario...
//   kill -TERM $!
//
// CPU is the sum over processes of utime + stime at their last sample, so a
// process that lives less than one interval is missed, and the CPU a process used
// after its last sample is too. Meant for comparing runs, not for absolute numbers.
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const binary = fs.realpathSync(process.argv[2] ?? process.env.CDP_EX_CHROME_BINARY);
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 100);
const ticksPerSecond = Number(execFileSync("getconf", ["CLK_TCK"]).toString().trim());

let peakPssKb = 0;
let peakProcs = 0;
// "pid:starttime" -> utime + stime in ticks, so a reused pid counts as a new process.
const cpuTicks = new Map();

function read(path) {
  try {
    return fs.readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function exe(pid) {
  try {
    return fs.readlinkSync(`/proc/${pid}/exe`);
  } catch {
    return null;
  }
}

function sample() {
  let pssKb = 0;
  let procs = 0;

  for (const pid of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(pid) || exe(pid) !== binary) continue;

    const stat = read(`/proc/${pid}/stat`);
    const rollup = read(`/proc/${pid}/smaps_rollup`);
    if (stat === null || rollup === null) continue;

    // Fields after the parenthesised command name: utime is 14th, stime 15th,
    // starttime 22nd of the whole line.
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    cpuTicks.set(`${pid}:${fields[19]}`, Number(fields[11]) + Number(fields[12]));

    const pss = rollup.match(/^Pss:\s+(\d+) kB/m);
    if (pss) pssKb += Number(pss[1]);
    procs++;
  }

  peakPssKb = Math.max(peakPssKb, pssKb);
  peakProcs = Math.max(peakProcs, procs);
}

const timer = setInterval(sample, INTERVAL_MS);
sample();

process.on("SIGTERM", () => {
  clearInterval(timer);
  sample();
  const ticks = [...cpuTicks.values()].reduce((a, b) => a + b, 0);

  console.log(
    JSON.stringify({
      peak_pss_mb: Math.round(peakPssKb / 1024),
      peak_procs: peakProcs,
      cpu_s: Number((ticks / ticksPerSecond).toFixed(2)),
    }),
  );

  process.exit(0);
});
