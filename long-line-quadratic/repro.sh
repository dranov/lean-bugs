#!/usr/bin/env bash
# Time parsing and .ilean writing of the same term on one line vs. one element per line.
# See README.md.
#
# Usage: ./repro.sh [TOOLCHAIN]
#   TOOLCHAIN  optional elan toolchain, e.g. leanprover/lean4:v4.34.1
#              (default: the one in lean-toolchain)
# Environment:
#   SIZES  element counts to sweep (default: 2000 4000 8000)
#
# Writes out/N/{OneLine,MultiLine}.lean, which differ only in line breaks, and
# prints wall seconds for `lean FILE` and `lean FILE -i FILE.ilean` on each.
# Runs are sequential. The defaults take about 2 minutes; N=16000 alone about 5.
set -euo pipefail
cd "$(dirname "$0")"
SIZES=${SIZES:-"2000 4000 8000"}
TC=${1:-}
LEAN=(lean)
[ -n "$TC" ] && LEAN=(lean "+$TC")

# gen SEP N: the list [{ x := id 0, y := id 0 }, ..., { x := id N, y := id N }],
# with SEP between elements.
gen() {
  printf 'set_option maxRecDepth 100000\n\nstructure Foo where\n  x : Nat\n  y : Nat\n\ndef big : List Foo := [{ x := id 0, y := id 0 }'
  i=1
  while [ "$i" -le "$2" ]; do printf "$1{ x := id $i, y := id $i }"; i=$((i + 1)); done
  printf ']\n'
}

# wall CMD...: run CMD, fail if it fails or prints anything, print wall seconds.
wall() {
  local t0 t1 out
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  out=$("$@" 2>&1) || { echo "$out" >&2; echo "error: $* failed" >&2; exit 1; }
  [ -z "$out" ] || { echo "$out" >&2; echo "error: $* printed output" >&2; exit 1; }
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }'
}

"${LEAN[@]}" --version
# Warm up (first `lean` run after a toolchain switch is slower).
mkdir -p out; gen ', ' 10 > out/warmup.lean; wall "${LEAN[@]}" out/warmup.lean > /dev/null
echo
printf '| %6s | %10s | %8s | %13s | %10s | %15s |\n' N "line bytes" "one line" "one line \`-i\`" multi-line "multi-line \`-i\`"
printf '|%s|%s|%s|%s|%s|%s|\n' '-------:' '-----------:' '---------:' '--------------:' '-----------:' '----------------:'
for n in $SIZES; do
  d=out/$n; mkdir -p "$d"
  gen ', ' "$n" > "$d/OneLine.lean"        # the whole list on one line
  gen ',\n  ' "$n" > "$d/MultiLine.lean"   # the same list, one element per line
  bytes=$(awk '{ if (length > m) m = length } END { print m }' "$d/OneLine.lean")
  o=$(wall "${LEAN[@]}" "$d/OneLine.lean")
  oi=$(wall "${LEAN[@]}" "$d/OneLine.lean" -i "$d/OneLine.ilean")
  m=$(wall "${LEAN[@]}" "$d/MultiLine.lean")
  mi=$(wall "${LEAN[@]}" "$d/MultiLine.lean" -i "$d/MultiLine.ilean")
  printf '| %6s | %10s | %8s | %13s | %10s | %15s |\n' "$n" "$bytes" "$o" "$oi" "$m" "$mi"
done
