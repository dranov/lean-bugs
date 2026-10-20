#!/bin/sh
# Reproduce the Lake build-cycle deadlock. See README.md.
#
# Usage: ./repro.sh [TOOLCHAIN]
#   TOOLCHAIN  optional elan toolchain, e.g. leanprover/lean4:v4.35.0
#              (default: the one in lean-toolchain)
#   LIMIT      env var, seconds before a build counts as hung (default 20)
#
# Every case should end in "build cycle detected". Exit status: 0 if all
# cases did, 1 otherwise (e.g. if a case deadlocked).
set -u
cd "$(dirname "$0")" || exit 2
LIMIT=${LIMIT:-20}
TC=${1:-}
LOGS=$(mktemp -d) || exit 2
trap 'rm -rf "$LOGS"' EXIT

lake() { if [ -n "$TC" ]; then command lake "+$TC" "$@"; else command lake "$@"; fi; }

# with_timeout SECS CMD...: run CMD; kill it after SECS seconds and return 124.
with_timeout() {
  secs=$1; shift
  rm -f "$LOGS/timed-out"
  "$@" &
  pid=$!
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1))
    done
    touch "$LOGS/timed-out"
    kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
  ) &
  watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  if [ -e "$LOGS/timed-out" ]; then return 124; fi
  return "$rc"
}

lake --version || exit 2
# Start clean and elaborate the lakefile outside the per-case time limit.
rm -rf .lake
if ! with_timeout 600 lake env true >"$LOGS/config.log" 2>&1; then
  cat "$LOGS/config.log"; echo "error: could not load lakefile.lean"; exit 2
fi

status=0
# case LABEL TARGETS...: `lake build TARGETS` and classify the outcome.
case_() {
  label=$1; shift
  log="$LOGS/$label.log"
  with_timeout "$LIMIT" lake build "$@" >"$log" 2>&1; rc=$?
  if [ "$rc" -eq 124 ]; then outcome="deadlock (timed out after ${LIMIT}s)"; status=1
  elif grep -q "build cycle detected" "$log"; then outcome="cycle reported"
  elif [ "$rc" -eq 0 ]; then outcome="built"; status=1
  else outcome="failed with another error (exit $rc)"; status=1
  fi
  printf '\n%-8s lake build %s\n         -> %s\n' "$label" "$*" "$outcome"
  sed 's/^/         | /' "$log"
}

case_ bug     dynA dynB
case_ control staticA staticB
case_ one-root dynA
case_ self    self
case_ three   tri1 tri2 tri3
exit "$status"
