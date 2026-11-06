# One image for the competitor comparison (bench/compare/README.md): Debian's
# Chromium and the matching chromium-driver, so CDPEx, playwright_ex,
# ChromicPDF and Wallaby all drive the same browser, natively on amd64 and arm64.
FROM debian:trixie-slim

ARG ELIXIR_VERSION=1.20.5
ARG ELIXIR_OTP=27
ARG PLAYWRIGHT_VERSION=1.64.1

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/opt/elixir/bin:$PATH \
    CHROME=/usr/bin/chromium \
    CDP_EX_CHROME_BINARY=/usr/bin/chromium \
    MIX_ENV=prod

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git procps unzip \
      erlang-nox erlang-dev erlang-xmerl \
      chromium chromium-driver \
      nodejs npm ghostscript \
      fonts-liberation fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    base="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}"; \
    zip="elixir-otp-${ELIXIR_OTP}.zip"; \
    cd /tmp; \
    curl -fsSLO "$base/$zip"; \
    curl -fsSL "$base/$zip.sha256sum" | sha256sum -c -; \
    unzip -q "$zip" -d /opt/elixir; \
    rm "$zip"; \
    elixir --version

# The Playwright driver playwright_ex talks to. Its own browsers aren't
# downloaded: playwright_ex is pointed at Debian's Chromium.
RUN set -eux; \
    mkdir -p /opt/playwright; \
    npm install --prefix /opt/playwright --no-audit --no-fund "playwright-core@${PLAYWRIGHT_VERSION}"; \
    printf '#!/bin/sh\nexec node /opt/playwright/node_modules/playwright-core/cli.js "$@"\n' >/usr/local/bin/playwright; \
    chmod +x /usr/local/bin/playwright; \
    playwright --version; \
    chromium --version; \
    chromedriver --version

RUN useradd --create-home app \
 && mkdir -p /app/deps /app/_build /app/bench/compare/deps /app/bench/compare/_build \
 && chown -R app:app /app
USER app
WORKDIR /app/bench/compare
RUN mix local.hex --force && mix local.rebar --force
