# Linux test containers

Runs an integration test repeatedly on Ubuntu 26.04 against a Linux browser
and reports any `cdp_ex-*` profile dir or Chrome process a run leaves behind.
Used for `docs/TODO.md` item 2. For local development only: production hosts
don't run Docker. Not part of the Hex package.

The `chrome` image mirrors the production target: Ubuntu 26.04, amd64,
Elixir 1.20.5. Docker Desktop brings its own Linux kernel, so the kernel
version differs from the host's.

```bash
test/docker/run.sh chromium   # Playwright's Chromium, native arch
test/docker/run.sh chrome     # Google Chrome stable, linux/amd64
```

The repository is bind-mounted at `/app`; `deps` and `_build` live in named
volumes per browser (`cdp_ex-deps-<browser>`, `cdp_ex-build-<browser>`), so the
host's build is never touched.

Environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNS`   | `20`    | Number of runs |
| `TEST`   | `test/cdp_ex/integration_test.exs:1712` | Test location to run |
| `TRACE`  | `0`     | `1` runs each test under `strace` and prints the process that created a leftover dir |
| `CPUS`   | `0`     | CPU cap for the container; `0` means no cap |

Notes:

- Google Chrome has no Linux arm64 build. On Apple Silicon the `chrome` image
  runs under emulation: timings are slower than on a real amd64 host, and the
  BEAM runs with `+JMsingle true` because its JIT segfaults there otherwise.
- The container runs as a non-root user, as on a production host.
