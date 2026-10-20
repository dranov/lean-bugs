#!/usr/bin/env bash
# Usage: ./repro.sh [TOOLCHAIN] [RUNS]
# Builds each target RUNS times from a clean .lake and prints how many times
# the job of `shared` ran in each build. Expected: 1 every time.
set -euo pipefail
cd "$(dirname "$0")"
toolchain=${1:-$(cat lean-toolchain)}
runs=${2:-10}
lake +"$toolchain" --version
for target in dynamic serialised static; do
  counts=() bad=0
  for _ in $(seq "$runs"); do
    rm -rf .lake
    lake +"$toolchain" build -q "$target" >/dev/null
    n=$(wc -l < .lake/build/shared.log | tr -d ' ')
    counts+=("$n")
    [ "$n" = 1 ] || bad=$((bad + 1))
  done
  printf '%-10s shared built: %s  (runs with duplicates: %d/%d)\n' \
    "$target" "${counts[*]}" "$bad" "$runs"
done
