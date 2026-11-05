# Ubuntu image for running the integration tests against a Linux Chrome.
#
#   BROWSER=chromium  Playwright's Chromium build; native on amd64 and arm64.
#   BROWSER=chrome    Google Chrome stable; amd64 only (emulated on Apple Silicon).
#
# The repository is bind-mounted at /app at run time; see test/docker/run.sh.
FROM ubuntu:26.04

ARG BROWSER=chromium
ARG PLAYWRIGHT_VERSION=1.64.1
# Ubuntu's own elixir package is older than production's; Erlang/OTP comes from
# Ubuntu (27 on 26.04) and Elixir from the precompiled release for that OTP.
ARG ELIXIR_VERSION=1.20.5
ARG ELIXIR_OTP=27

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/opt/elixir/bin:$PATH \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    CDP_EX_CHROME_BINARY=/usr/local/bin/cdp-ex-browser \
    MIX_ENV=test

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git procps strace unzip \
      erlang-nox erlang-dev erlang-dialyzer \
      fonts-liberation \
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

RUN set -eux; \
    case "$BROWSER" in \
      chrome) \
        test "$(dpkg --print-architecture)" = amd64 || { echo "Google Chrome is amd64 only"; exit 1; }; \
        curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
        apt-get update; \
        apt-get install -y --no-install-recommends /tmp/chrome.deb; \
        rm -rf /tmp/chrome.deb /var/lib/apt/lists/*; \
        ln -s /usr/bin/google-chrome-stable "$CDP_EX_CHROME_BINARY" ;; \
      chromium) \
        apt-get update; \
        apt-get install -y --no-install-recommends nodejs npm; \
        npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium; \
        apt-get purge -y npm; apt-get autoremove -y; \
        rm -rf /var/lib/apt/lists/* /root/.npm; \
        bin="$(find "$PLAYWRIGHT_BROWSERS_PATH" -path '*chromium-*' -type f -name chrome | head -n1)"; \
        test -x "$bin"; \
        ln -s "$bin" "$CDP_EX_CHROME_BINARY" ;; \
      *) echo "unknown BROWSER=$BROWSER"; exit 1 ;; \
    esac; \
    "$CDP_EX_CHROME_BINARY" --version

# A non-root user, as on a production host. deps and _build live in named
# volumes; creating them here gives the volumes this user's ownership.
RUN useradd --create-home app \
 && mkdir -p /app/deps /app/_build \
 && chown -R app:app /app
USER app
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENTRYPOINT ["/app/test/docker/leak_loop.sh"]
