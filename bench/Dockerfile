# Benchmark image: the test/docker Chromium image plus playwright-core, so CDPEx
# and Playwright drive the same Chromium build. Built by bench/docker.sh, which
# builds the base image first.
ARG BASE=cdp_ex-test:chromium
FROM ${BASE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends npm \
 && rm -rf /var/lib/apt/lists/*

# Outside /app: the repository is bind-mounted there at run time.
COPY package.json package-lock.json /opt/bench/
RUN npm ci --prefix /opt/bench --no-audit --no-fund \
 && chown -R app:app /opt/bench

ENV PLAYWRIGHT_CORE=/opt/bench/node_modules/playwright-core/index.mjs
USER app
ENTRYPOINT ["/app/bench/run.sh"]
