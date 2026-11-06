#!/usr/bin/env python3
"""Builds fixture/html/ from a saved Wikipedia article. Run once; the output is
committed. Usage:

    python3 -I bench/compare/fixture/make_html.py Saint_Petersburg

Downloads the article and its two skin stylesheets, drops every <script>,
and points every image at the fixture server's generated placeholder of the
same size (/img/<w>x<h>/<n>.png), so no image file needs a licence of its own.
"""
import html, re, sys, urllib.request
from pathlib import Path

UA = "cdp_ex-bench-fixture/1.0"
BASE = "https://en.wikipedia.org"
out = Path(__file__).resolve().parent / "html"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req) as r:
        return r.read().decode("utf-8")


title = sys.argv[1]
page = get(f"{BASE}/wiki/{title}")

css_links = re.findall(r'<link rel="stylesheet" href="([^"]+)"[^>]*>', page)
for i, href in enumerate(css_links):
    (out / f"style{i}.css").write_text(get(BASE + html.unescape(href)))
    page = page.replace(f'href="{href}"', f'href="style{i}.css"', 1)

page = re.sub(r"<script\b[^>]*>.*?</script>", "", page, flags=re.S)
page = re.sub(r'<link rel="(?:preload|modulepreload|preconnect|dns-prefetch)"[^>]*>', "", page)

n = 0


def img(m):
    global n
    tag = m.group(0)
    w = re.search(r'\swidth="(\d+)"', tag)
    h = re.search(r'\sheight="(\d+)"', tag)
    w, h = (int(w.group(1)) if w else 100), (int(h.group(1)) if h else 100)
    n += 1
    tag = re.sub(r'\ssrcset="[^"]*"', "", tag)
    return re.sub(r'\ssrc="[^"]*"', f' src="/img/{w}x{h}/{n}.png"', tag)


page = re.sub(r"<img\b[^>]*>", img, page)
# Links to other wiki pages would leave the fixture; keep the text, drop the target.
page = re.sub(r'href="(?:/wiki/|//|https?://)[^"]*"', 'href="#"', page)
(out / "index.html").write_text(page)
print(f"{len(page)} bytes, {n} images, {len(css_links)} stylesheets")
