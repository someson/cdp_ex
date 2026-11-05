// Fixture server for the benchmark: a static page with sub-resources, and an SPA
// page that renders its content from a JSON API after load. Prints the port on
// stdout, then serves until killed.
//
//   node bench/fixture/server.mjs [port]
import http from "node:http";

const css = "body{font-family:sans-serif;margin:2em}.item{padding:4px;border-bottom:1px solid #ccc}";
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><circle cx="32" cy="32" r="30" fill="#48c"/></svg>';
const paragraphs = Array.from({ length: 40 }, (_, i) => `<p>Paragraph ${i} of the static fixture page.</p>`).join("");

const staticPage = `<!doctype html><html><head><meta charset="utf-8"><title>Static fixture</title>
<link rel="stylesheet" href="/style.css"></head><body><h1>Static</h1>
<img src="/img.svg" alt=""><img src="/img.svg?2" alt="">${paragraphs}</body></html>`;

const spaPage = `<!doctype html><html><head><meta charset="utf-8"><title>SPA fixture</title>
<link rel="stylesheet" href="/style.css"></head><body><div id="app">Loading…</div>
<script>
fetch("/api/items").then(r => r.json()).then(items => {
  document.getElementById("app").innerHTML =
    items.map(i => '<div class="item">' + i.name + "</div>").join("");
});
</script></body></html>`;

const items = JSON.stringify(Array.from({ length: 50 }, (_, i) => ({ id: i, name: `Item ${i}` })));

// The API answers after a short delay, as a real backend would.
const API_DELAY_MS = 20;

const routes = {
  "/": ["text/html; charset=utf-8", staticPage],
  "/spa": ["text/html; charset=utf-8", spaPage],
  "/style.css": ["text/css", css],
  "/img.svg": ["image/svg+xml", svg],
};

const server = http.createServer((req, res) => {
  const path = req.url.split("?")[0];

  if (path === "/api/items") {
    setTimeout(() => {
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      res.end(items);
    }, API_DELAY_MS);
    return;
  }

  const route = routes[path];
  if (!route) {
    res.writeHead(404).end();
    return;
  }

  res.writeHead(200, { "content-type": route[0], "cache-control": "no-store" });
  res.end(route[1]);
});

server.listen(Number(process.argv[2] ?? 0), "127.0.0.1", () => {
  console.log(server.address().port);
});
