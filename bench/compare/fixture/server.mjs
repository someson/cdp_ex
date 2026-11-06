// Fixture server for the competitor comparison (bench/compare/README.md).
//
//   node bench/compare/fixture/server.mjs
//
// Serves the three pages (/html/, /js/, /heavy/) to any Host, so it answers both
// as site.test and as embed.test (Docker network aliases; two different sites
// for Chrome, which puts the embed in its own process). Every response waits
// DELAY_MS (default 20) first.
//
//   /img/<w>x<h>/<name>.png  generated placeholder: 8 px blocks of colour, seeded by name
//   /fonts/<name>.ttf        a system font (serif-bold, sans, mono)
//   /api/...                 the JSON API behind /js/
//   /auth/                   the html page behind HTTP Basic auth (user / pass)
//   /_log, /_log/reset       requests seen since the last reset, for the probes
//
// PROXY_PORT (default 3128) is a plain HTTP forward proxy that wants
// Proxy-Authorization (user / pass) and logs every request it forwards.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 8080);
const PROXY_PORT = Number(process.env.PROXY_PORT ?? 3128);
const DELAY_MS = Number(process.env.DELAY_MS ?? 20);
const BASIC = "Basic " + Buffer.from("user:pass").toString("base64");

const FONTS = {
  "serif-bold.ttf": "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
  "sans.ttf": "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "mono.ttf": "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
};

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css",
  ".js": "text/javascript",
  ".json": "application/json",
  ".png": "image/png",
  ".ttf": "font/ttf",
};

let log = [];

// --- generated PNGs -------------------------------------------------------

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function seeded(str) {
  let s = 2166136261;
  for (const ch of str) s = Math.imul(s ^ ch.charCodeAt(0), 16777619);
  return () => {
    s = Math.imul(s ^ (s >>> 15), 2246822507) ^ Math.imul(s ^ (s >>> 13), 3266489909);
    return ((s ^= s >>> 16) >>> 0) / 4294967296;
  };
}

const pngCache = new Map();

function png(w, h, name) {
  const key = `${w}x${h}/${name}`;
  if (pngCache.has(key)) return pngCache.get(key);
  const rand = seeded(key);
  const bw = Math.ceil(w / 8);
  const bh = Math.ceil(h / 8);
  const blocks = Array.from({ length: bw * bh }, () => [rand() * 255, rand() * 255, rand() * 255]);
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    const row = y * (w * 3 + 1);
    raw[row] = 0;
    for (let x = 0; x < w; x++) {
      const [r, g, b] = blocks[Math.floor(y / 8) * bw + Math.floor(x / 8)];
      raw[row + 1 + x * 3] = r;
      raw[row + 2 + x * 3] = g;
      raw[row + 3 + x * 3] = b;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const out = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  pngCache.set(key, out);
  return out;
}

// --- the JSON API behind /js/ ---------------------------------------------

const rand = seeded("articles");
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const WORDS = "elixir otp browser protocol page proxy request context pool session render".split(" ");
const phrase = (n) => Array.from({ length: n }, () => pick(WORDS)).join(" ");
const ARTICLES = Array.from({ length: 40 }, (_, i) => ({
  slug: `article-${i + 1}`,
  title: `How to ${phrase(4)} (${i + 1})`,
  description: phrase(12),
  body: Array.from({ length: 6 }, () => phrase(60)).join("\n\n"),
  tagList: [pick(WORDS), pick(WORDS)],
  createdAt: new Date(Date.UTC(2026, 0, 1 + i)).toISOString(),
  favoritesCount: Math.floor(rand() * 200),
  author: { id: `a${i % 7}`, username: `author${i % 7}` },
}));

function api(url) {
  const [, , resource, slug, sub] = url.pathname.split("/");
  if (resource === "tags") return { tags: WORDS };
  if (resource !== "articles") return null;
  if (!slug) {
    const limit = Number(url.searchParams.get("limit") ?? 20);
    return { articles: ARTICLES.slice(0, limit), articlesCount: ARTICLES.length };
  }
  const article = ARTICLES.find((a) => a.slug === slug);
  if (!article) return null;
  if (sub === "comments") return { comments: [1, 2, 3].map((id) => ({ id, body: phrase(20) })) };
  return { article };
}

// --- server ---------------------------------------------------------------

function send(res, status, type, body) {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(body);
}

function file(res, rel) {
  const full = path.join(root, rel);
  if (!full.startsWith(root + path.sep)) return send(res, 404, "text/plain", "not found");
  fs.readFile(full, (err, data) => {
    if (err) return send(res, 404, "text/plain", "not found");
    send(res, 200, TYPES[path.extname(full)] ?? "application/octet-stream", data);
  });
}

function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const p = url.pathname;
  if (p === "/_log") return send(res, 200, TYPES[".json"], JSON.stringify(log));
  if (p === "/_log/reset") {
    log = [];
    return send(res, 200, "text/plain", "ok");
  }
  log.push({ host: url.hostname, path: p, proxied: req.headers["x-via-proxy"] === "1" });

  setTimeout(() => {
    let m;
    if ((m = p.match(/^\/img\/(\d+)x(\d+)\/([\w.-]+)\.png$/))) {
      const w = Math.min(Number(m[1]), 2000);
      const h = Math.min(Number(m[2]), 2000);
      return send(res, 200, TYPES[".png"], png(w, h, m[3]));
    }
    if ((m = p.match(/^\/fonts\/([\w.-]+)$/)) && FONTS[m[1]]) {
      return fs.readFile(FONTS[m[1]], (err, data) =>
        err ? send(res, 404, "text/plain", "no font") : send(res, 200, TYPES[".ttf"], data),
      );
    }
    if (p.startsWith("/api/")) {
      const body = api(url);
      return body ? send(res, 200, TYPES[".json"], JSON.stringify(body)) : send(res, 404, TYPES[".json"], "{}");
    }
    if (p === "/auth/" || p === "/auth") {
      if (req.headers.authorization !== BASIC) {
        res.writeHead(401, { "www-authenticate": 'Basic realm="fixture"' });
        return res.end("login required");
      }
      return send(res, 200, TYPES[".html"], "<!doctype html><title>Logged in</title><h1 id=ok>Logged in</h1>");
    }
    if (p === "/" || p === "") return send(res, 200, TYPES[".html"], "<!doctype html><title>fixture</title>ok");
    file(res, p.endsWith("/") ? p + "index.html" : p);
  }, DELAY_MS);
}

http.createServer(handle).listen(PORT, "0.0.0.0", () => console.log(`fixture on ${PORT}`));

// A forward proxy for absolute-URI HTTP requests, behind Proxy-Authorization.
http
  .createServer((req, res) => {
    if (req.headers["proxy-authorization"] !== BASIC) {
      res.writeHead(407, { "proxy-authenticate": 'Basic realm="proxy"' });
      return res.end("proxy login required");
    }
    const target = new URL(req.url);
    const headers = { ...req.headers, "x-via-proxy": "1" };
    delete headers["proxy-authorization"];
    const upstream = http.request(
      { host: "127.0.0.1", port: PORT, method: req.method, path: target.pathname + target.search, headers },
      (up) => {
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      },
    );
    upstream.on("error", () => send(res, 502, "text/plain", "bad gateway"));
    req.pipe(upstream);
  })
  .listen(PROXY_PORT, "0.0.0.0", () => console.log(`proxy on ${PROXY_PORT}`));
