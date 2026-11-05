// Playwright side of the benchmark, the same scenarios as bench/cdp_ex.exs:
//
//   BASE_URL=http://127.0.0.1:8080 SCENARIO=cold node bench/playwright.mjs
//
// Uses playwright-core with the browser at CDP_EX_CHROME_BINARY, so both libraries
// drive the same build. PLAYWRIGHT_CORE overrides where playwright-core is loaded
// from (the bench image installs it outside the bind-mounted repository).
const { chromium } = await import(process.env.PLAYWRIGHT_CORE ?? "playwright-core");

const env = (name, fallback) => process.env[name] ?? fallback;
const int = (name, fallback) => Number.parseInt(env(name, String(fallback)), 10);

const base = env("BASE_URL", "http://127.0.0.1:8080").replace(/\/$/, "");
const scenario = env("SCENARIO", "cold");
const launchOpts = { headless: true, executablePath: env("CDP_EX_CHROME_BINARY", undefined) };

// browser.newPage() opens the page in a fresh context, Playwright's default unit.
async function job(browser, path, check) {
  const page = await browser.newPage();
  await page.goto(base + path, { waitUntil: "load" });
  await check(page);
  await page.close();
}

const title = (page) => page.title();
const items = (page) => page.waitForSelector(".item");

async function timed(fn) {
  const t0 = performance.now();
  await fn();
  return performance.now() - t0;
}

async function cold() {
  const cycle = async () => {
    const browser = await chromium.launch(launchOpts);
    await job(browser, "/", title);
    await browser.close();
  };

  await cycle();
  const samples = [];
  for (let i = 0; i < int("ITERATIONS", 10); i++) samples.push(await timed(cycle));
  return { samples_ms: samples };
}

async function spa() {
  const browser = await chromium.launch(launchOpts);
  await job(browser, "/spa", items);
  const samples = [];
  for (let i = 0; i < int("ITERATIONS", 20); i++) samples.push(await timed(() => job(browser, "/spa", items)));
  await browser.close();
  return { samples_ms: samples };
}

async function concurrent() {
  const browser = await chromium.launch(launchOpts);
  await job(browser, "/", title);
  const seconds = int("DURATION_S", 20);
  const deadline = performance.now() + seconds * 1000;

  const worker = async () => {
    let jobs = 0;
    while (performance.now() < deadline) {
      await job(browser, "/", title);
      jobs++;
    }
    return jobs;
  };

  const t0 = performance.now();
  const counts = await Promise.all(Array.from({ length: int("CONCURRENCY", 8) }, worker));
  const elapsed = (performance.now() - t0) / 1000;
  await browser.close();
  return { jobs: counts.reduce((a, b) => a + b, 0), seconds: elapsed };
}

const scenarios = { cold, spa, concurrent };
if (!scenarios[scenario]) throw new Error(`unknown SCENARIO ${scenario}`);
console.log(JSON.stringify({ lib: "playwright", scenario, ...(await scenarios[scenario]()) }));
