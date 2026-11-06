import Config

# Wallaby: Debian's chromedriver and Chromium, the same browser as the others.
# Its default capabilities already set a 1280x800 headless window.
config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_dir: "/tmp/wallaby-screenshots",
  chromedriver: [path: "/usr/bin/chromedriver", binary: "/usr/bin/chromium"]

config :logger, level: :warning
