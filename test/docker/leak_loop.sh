#!/usr/bin/env bash
# Runs one integration test RUNS times and reports, after each run, any new
# cdp_ex-* dir in the temp dir and any Chrome process left behind.
#
#   RUNS   number of runs (default 20)
#   TEST   test location (default: the launch cut short by launch_timeout)
#   TRACE  1 = run each test under strace and, for a leftover dir, print the
#          process that created it (needs --cap-add SYS_PTRACE)
set -uo pipefail

RUNS="${RUNS:-20}"
TEST="${TEST:-test/cdp_ex/integration_test.exs:1712}"
TRACE="${TRACE:-0}"
TMP="${TMPDIR:-/tmp}"
LOGS="$TMP/leak_loop"

mkdir -p "$LOGS"
echo "browser: $("$CDP_EX_CHROME_BINARY" --version) ($(dpkg --print-architecture))"
echo "elixir:  $(elixir --version | tail -n1)"
mix deps.get >/dev/null 2>&1 && mix compile >/dev/null 2>&1 || exit 1

list_dirs() { find "$TMP" -maxdepth 1 -name 'cdp_ex-*' -type d | sort; }

pass=0 fail=0 leaky=0
for i in $(seq 1 "$RUNS"); do
  before="$(list_dirs)"
  trace="$LOGS/strace-$i.log"
  if [ "$TRACE" = 1 ]; then
    cmd=(strace -f -qq -e trace=execve,mkdir,mkdirat -o "$trace" mix test "$TEST" --include integration)
  else
    cmd=(mix test "$TEST" --include integration)
  fi

  if "${cmd[@]}" >"$LOGS/test-$i.log" 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "run $i: test failed, see $LOGS/test-$i.log"
  fi

  sleep 1
  new="$(comm -13 <(echo "$before") <(list_dirs))"
  if [ -n "$new" ]; then
    leaky=$((leaky + 1))
    for d in $new; do
      echo "run $i: leftover $d ($(find "$d" -mindepth 1 | wc -l) entries)"
      if [ "$TRACE" = 1 ]; then
        # strace -f lines start with the pid; map the creating pid to the binary it exec'd.
        grep -F "\"$d" "$trace" | grep -E 'mkdir(at)?\(' | while read -r pid rest; do
          exe="$(grep -E "^$pid execve\(" "$trace" | tail -n1 | sed -E 's/^[0-9]+ execve\("([^"]+)".*/\1/')"
          echo "  pid $pid (${exe:-forked, no exec}): ${rest:0:160}"
        done
      fi
    done
  fi

  orphans="$(pgrep -af 'cdp_ex-' || true)"
  [ -n "$orphans" ] && echo "run $i: Chrome left running:" && echo "$orphans"
done

echo "runs=$RUNS pass=$pass fail=$fail runs_with_leftover_dir=$leaky"
