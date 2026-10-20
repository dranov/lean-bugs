#!/usr/bin/env bash
# Measure Lake's Job collection combinators against a linear control. See README.md.
#
# Usage: ./repro.sh [TOOLCHAIN]
#   TOOLCHAIN  optional elan toolchain, e.g. leanprover/lean4:v4.35.0
#              (default: the one in lean-toolchain)
# Environment:
#   SIZES     job counts for the sweep (default: 1000 2000 4000 8000 16000 32000 64000)
#   MATRIX_N  job count for the per-combinator table (default: 16000)
#   LIMIT     seconds before a single `lake build` is killed (default: 300)
#
# Times are measured inside the build: from building the collection job until
# the collected job has finished.
set -euo pipefail
cd "$(dirname "$0")"
SIZES=${SIZES:-"1000 2000 4000 8000 16000 32000 64000"}
MATRIX_N=${MATRIX_N:-16000}
LIMIT=${LIMIT:-300}
TC=${1:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

LAKE=(lake)
[ -n "$TC" ] && LAKE=(lake "+$TC")

# with_timeout SECS CMD...: run CMD; kill it after SECS seconds and fail.
with_timeout() {
  local secs=$1; shift
  "$@" & local pid=$!
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
  ) &
  local watcher=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# run TARGET: `lake build TARGET` with the current N/INPUTS/LOGS; sets MS
# (collection time in ms).
run() {
  if ! with_timeout "$LIMIT" "${LAKE[@]}" build "$1" >"$TMP/out" 2>&1; then
    cat "$TMP/out"; echo "error: lake build $1 failed or timed out after ${LIMIT}s" >&2; exit 1
  fi
  MS=$(awk '/RESULT/ { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
                       printf "%.1f", (v["build_us"] + v["wait_us"]) / 1000 }' "$TMP/out")
}

"${LAKE[@]}" --version
echo "cores: $(sysctl -n hw.ncpu 2>/dev/null || nproc)"
# Start clean and elaborate the lakefile once, outside the measurements.
rm -rf .lake
N=0 with_timeout 600 "${LAKE[@]}" build linear >"$TMP/out" 2>&1 \
  || { cat "$TMP/out"; echo "error: could not load lakefile.lean" >&2; exit 1; }

# sweep COMBINATOR: collection time of COMBINATOR and of the control for each N
# in SIZES, with the current INPUTS/LOGS. Control times are cached per LOGS.
sweep() {
  local t=$1 n c l
  printf '| %6s | %15s | %9s | %6s |\n' N "$t ms" "linear ms" ratio
  printf '|-------:|----------------:|----------:|-------:|\n'
  for n in $SIZES; do
    export N=$n
    run "$t"; c=$MS
    if [ -f "$TMP/linear-$LOGS-$n" ]; then l=$(cat "$TMP/linear-$LOGS-$n")
    else run linear; l=$MS; echo "$l" > "$TMP/linear-$LOGS-$n"; fi
    printf '| %6s | %15s | %9s | %5sx |\n' "$n" "$c" "$l" \
      "$(awk -v a="$c" -v b="$l" 'BEGIN { printf "%.0f", a / b }')"
  done
}

export INPUTS=pending
echo
echo "Each table: INPUTS=pending, collection time in ms (measured inside the build) of a"
echo "combinator against the linear control. The array combinators are quadratic with no"
echo "log entries; the list combinators only when the inputs have log entries."
for t in collectArray mixArray collectVector; do
  echo; echo "$t (LOGS=0):"; echo
  LOGS=0 sweep "$t"
done
for t in collectList mixList; do
  echo; echo "$t (LOGS=1):"; echo
  LOGS=1 sweep "$t"
done

echo
echo "Each combinator at N=$MATRIX_N (collection time in ms):"
echo
printf '| %-14s | %16s | %16s | %16s | %16s |\n' combinator \
  "pending, no logs" "pending, logs" "done, no logs" "done, logs"
printf '|----------------|------------------|------------------|------------------|------------------|\n'
export N=$MATRIX_N
for t in collectArray mixArray collectVector collectList mixList linear; do
  row=()
  for inputs in pending done; do
    for logs in 0 1; do
      INPUTS=$inputs LOGS=$logs run "$t"; row+=("$MS")
    done
  done
  printf '| %-14s | %16s | %16s | %16s | %16s |\n' "$t" "${row[@]}"
done
